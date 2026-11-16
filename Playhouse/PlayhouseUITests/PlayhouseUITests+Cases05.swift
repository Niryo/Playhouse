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
    // case-contract: test_merged_task_renew_opens_fresh_worktree_and_new_pr | `task repository renew` starts follow-up Git work after a pull request merged. It is rejected while the repository has no linked pull request, while the linked pull request is unmerged, and while the merged worktree has uncommitted changes, leaving the task unchanged. A merged PR status read persists that it merged, and the next turn is told the merged branch is finished and to renew before Git changes. Renewing from inside the agent's turn retires the record with its merged PR to the task's past repositories, keeps the merged branch, removes the old worktree once that turn ends, and creates a fresh worktree on a new suffixed branch based on the merge target as just fetched from the remote, so it holds the merged commits even when the local target is stale. A new pull request then opens from the fresh worktree, and the card shows the merged PR in purple beside the new one; once the task is Done, the archive row lists both. A Done task renews too: a follow-up to it returns it to In Progress before its turn starts, and `task repository renew` on a Done task does the same, each with a fresh worktree for every repository whose worktree was removed (a past link only for records that had a pull request); that turn's completed outcome moves it to Review, keeping both merged PRs on fresh reads.
    func test_merged_task_renew_opens_fresh_worktree_and_new_pr() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [])
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        let remoteRoot = dataDirectory.appendingPathComponent("renew-remotes", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.path), "Each case must start with an isolated remote.")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(to: remoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
        XCTAssertFalse(try runGitOutput(fixture.primary, "remote").split(whereSeparator: \.isNewline).contains("origin"), "The isolated source fixture must not already have an origin remote.")
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        let remote = remoteRoot.appendingPathComponent("primary.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        try runGit(fixture.primary, "push", "origin", "main")

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Renew merged work UI", "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path, "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Renew merged work UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Renew merged work UI")
        element("back-to-board-button").click()
        let old = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let oldBranch = try XCTUnwrap(old["branch"] as? String)
        let oldWorktree = URL(fileURLWithPath: try XCTUnwrap(old["worktreePath"] as? String))
        let renew = ["task", "repository", "renew", taskID, "--repo", fixture.primary.path]
        let noPullRequest = try runCLI(renew, expectedStatus: 1, extraEnvironment: ghEnvironment)
        XCTAssertTrue(((noPullRequest["error"] as? [String: Any])?["message"] as? String ?? "").contains("no merged pull request"))

        XCTAssertTrue(terminateAppAndWait(app), "Close Playhouse before seeding the linked pull request.")
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/playhouse-test/fixture/pull/123")
        try "123=unmerged\n".write(to: stateURL, atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let unmerged = try runCLI(renew, expectedStatus: 1, extraEnvironment: ghEnvironment)
        XCTAssertTrue(((unmerged["error"] as? [String: Any])?["message"] as? String ?? "").contains("#123 isn't merged yet"))

        // GitHub merges the PR: the remote target gains the merged commit while the local target stays stale.
        let merger = remoteRoot.appendingPathComponent("merger", isDirectory: true)
        try runGit(remoteRoot, "clone", "--quiet", "--branch", "main", remote.path, merger.path)
        try "Merged pull request #123.\n".write(to: merger.appendingPathComponent("merged-on-github.txt"), atomically: true, encoding: .utf8)
        try runGit(merger, "add", "merged-on-github.txt")
        try runGit(merger, "-c", "user.name=Playhouse Test", "-c", "user.email=test@playhouse.invalid", "commit", "-m", "Merge pull request #123")
        try runGit(merger, "push", "origin", "HEAD:main")
        let mergedHead = try runGitOutput(merger, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try "123=merged\n".write(to: stateURL, atomically: true, encoding: .utf8)
        _ = try runCLI(["task", "pr", "status", taskID], extraEnvironment: ghEnvironment)
        XCTAssertEqual((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["isPullRequestMerged"] as? Bool, true)
        openTask(named: "Renew merged work UI")
        var renewedRecord: [String: Any]?
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Renew merged work UI", prompt: "Can you follow up on the merged change?", whileTurnHeld: { [self] in
            // The agent renews from inside its own turn, as the instructions tell it to.
            try "uncommitted\n".write(to: oldWorktree.appendingPathComponent("left-behind.txt"), atomically: true, encoding: .utf8)
            let dirty = try runCLI(renew, expectedStatus: 1, extraEnvironment: ghEnvironment)
            XCTAssertTrue(((dirty["error"] as? [String: Any])?["message"] as? String ?? "").contains("uncommitted changes"))
            try FileManager.default.removeItem(at: oldWorktree.appendingPathComponent("left-behind.txt"))
            renewedRecord = try runCLI(renew, extraEnvironment: ghEnvironment)["result"] as? [String: Any]
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldWorktree.path), "The merged worktree stays while the turn that renewed it still runs.")
        })
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))) as? [String: Any]
        // Later resumes carry the renewed mapping; the turn itself started with the merged guidance.
        let instructions = ((history?["threadResumeDeveloperInstructions"] as? [Any]) ?? []).compactMap { $0 as? String }
            .first { $0.contains("Merged pull requests:") } ?? ""
        let repositoryPath = try XCTUnwrap(old["repositoryPath"] as? String)
        XCTAssertTrue(instructions.contains("Merged pull requests: #123 for \(repositoryPath) (branch \(oldBranch))"), "The next turn is told which PR merged.")
        XCTAssertTrue(instructions.contains("do not commit or push to it"))
        XCTAssertTrue(instructions.contains("task repository renew \(taskID) --repo <path>"))
        element("back-to-board-button").click()

        let renewed = try XCTUnwrap(renewedRecord)
        XCTAssertEqual(renewed["status"] as? String, "In Progress", "Renewing mid-turn leaves the running turn's status alone.")
        let fresh = try XCTUnwrap((renewed["repositoryWorktrees"] as? [[String: Any]])?.first)
        let freshBranch = try XCTUnwrap(fresh["branch"] as? String)
        XCTAssertNotEqual(freshBranch, oldBranch)
        XCTAssertTrue(freshBranch.range(of: "^renew-merged-work-ui-[a-z0-9]{4}$", options: .regularExpression) != nil, "Unexpected fresh branch \(freshBranch)")
        XCTAssertEqual(fresh["branchFrom"] as? String, "origin/main")
        let freshWorktree = URL(fileURLWithPath: try XCTUnwrap(fresh["worktreePath"] as? String))
        XCTAssertEqual(try runGitOutput(freshWorktree, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), mergedHead, "The fresh worktree starts from the merge target as just fetched.")
        let past = try XCTUnwrap(renewed["pastRepositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(past.compactMap { $0["pullRequestNumber"] as? Int }, [123])
        XCTAssertEqual(past.first?["branch"] as? String, oldBranch)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: oldWorktree.path) }, timeout: 20), "The merged worktree is removed once the turn that renewed it ends.")
        XCTAssertFalse(try runGitOutput(fixture.primary, "branch", "--list", oldBranch).isEmpty, "Renewing keeps the merged branch.")

        let mergedLink = app.links["task-pr-link-\(taskID)-123"]
        XCTAssertTrue(mergedLink.waitToExist(timeout: 10), "The merged PR stays on the card after renewing.")
        XCTAssertEqual(mergedLink.value as? String, "merged", "The retired PR reads as merged (purple).")
        let createPRButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(createPRButton.waitToExist(timeout: 10), "The fresh worktree offers a new pull request beside the merged one.")
        revealOnBoard(createPRButton)
        attachScreenshot(named: "Renewed task keeps the merged PR beside a new PR action")
        try "Follow-up after the merge.\n".write(to: freshWorktree.appendingPathComponent("follow-up.txt"), atomically: true, encoding: .utf8)
        createPRButton.click()
        let newLink = app.links["task-pr-link-\(taskID)-501"]
        XCTAssertTrue(newLink.waitToExist(timeout: 30), "The new pull request opens from the fresh worktree.")
        XCTAssertTrue(mergedLink.exists, "The merged PR stays beside the new one.")
        XCTAssertEqual(mergedLink.value as? String, "merged")
        let createLog = try String(contentsOfFile: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"]), encoding: .utf8)
        let createTargets = createLog.components(separatedBy: "\n").filter { $0.hasPrefix("create\t") }
            .compactMap { $0.split(separator: "\t", maxSplits: 2).dropFirst().first.map(String.init) }
            .map { $0.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        XCTAssertEqual(createTargets, [freshWorktree.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")])
        attachScreenshot(named: "Merged PR in purple beside the new PR")

        try "123=merged\n501=merged\n".write(to: stateURL, atomically: true, encoding: .utf8)
        XCTAssertEqual((try runCLI(["task", "move", taskID, "Done"], extraEnvironment: ghEnvironment)["result"] as? [String: Any])?["status"] as? String, "Done")
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitToExist(timeout: 10))
        let archivedMerged = app.links["done-archive-pr-link-\(taskID)-123"]
        let archivedNew = app.links["done-archive-pr-link-\(taskID)-501"]
        XCTAssertTrue(archivedMerged.waitToExist(timeout: 10), "The Done archive row keeps the PR merged before the renew.")
        XCTAssertTrue(archivedNew.waitToExist(timeout: 10), "The Done archive row lists the new PR beside it.")
        XCTAssertLessThan(archivedMerged.frame.minX, archivedNew.frame.minX, "The earlier merged PR comes first.")
        attachScreenshot(named: "Done archive lists the merged PR beside the new one")
        element("done-archive-task-\(taskID)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        var reopenedRecord: [String: Any]?
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Renew merged work UI", prompt: "Please make one more change.", whileTurnHeld: { [self] in
            // The follow-up itself renewed the removed worktree before its turn started.
            reopenedRecord = try taskRecord(id: taskID)
            XCTAssertEqual(reopenedRecord?["status"] as? String, "In Progress", "A follow-up moves the Done task back to In Progress.")
        })
        XCTAssertFalse(element("archived-conversation-follow-up-hint").exists, "The reopened task is no longer archived.")
        element("back-to-board-button").click()
        let reopened = try XCTUnwrap(reopenedRecord)
        XCTAssertEqual((reopened["pastRepositoryWorktrees"] as? [[String: Any]])?.compactMap { $0["pullRequestNumber"] as? Int }, [123, 501])
        assertTaskVisible("Renew merged work UI", inColumn: "Review")
        let reopenedFirst = app.links["task-pr-link-\(taskID)-123"]
        let reopenedSecond = app.links["task-pr-link-\(taskID)-501"]
        XCTAssertTrue(reopenedFirst.waitToExist(timeout: 10) && reopenedSecond.waitToExist(timeout: 10), "The reopened card keeps both merged PRs.")
        XCTAssertEqual(reopenedFirst.value as? String, "merged")
        XCTAssertEqual(reopenedSecond.value as? String, "merged")
        revealOnBoard(reopenedSecond)
        attachScreenshot(named: "Reopened Done task keeps both merged PRs")
        let persisted = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(persisted["status"] as? String, "Review", "The reopening turn's completed outcome moves the task to Review, not back to Done.")
        XCTAssertEqual((persisted["pastRepositoryWorktrees"] as? [[String: Any]])?.compactMap { $0["pullRequestNumber"] as? Int }, [123, 501])

        // Reopening a multi-repository Done task renews every repository whose worktree was removed.
        let multi = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Renew both repositories UI", "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path, "--repo", fixture.secondary.path,
        ])["result"] as? [String: Any])
        let multiID = try XCTUnwrap(multi["id"] as? String)
        openTask(named: "Renew both repositories UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Renew both repositories UI")
        element("back-to-board-button").click()
        let before = try XCTUnwrap(try taskRecord(id: multiID)?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual((try runCLI(["task", "move", multiID, "Done"])["result"] as? [String: Any])?["status"] as? String, "Done")
        let both = try XCTUnwrap(try runCLI(["task", "repository", "renew", multiID, "--repo", fixture.primary.path], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual(both["status"] as? String, "In Progress")
        let after = try XCTUnwrap(both["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(after.count, 2)
        for (old, new) in zip(before, after) {
            XCTAssertEqual(new["repositoryPath"] as? String, old["repositoryPath"] as? String)
            XCTAssertNotEqual(new["worktreePath"] as? String, old["worktreePath"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(new["worktreePath"] as? String)), "Each repository of the reopened task gets a fresh worktree.")
        }
        XCTAssertEqual((both["pastRepositoryWorktrees"] as? [[String: Any]])?.count, 0, "Records without a pull request leave no past link.")
        assertTaskVisible("Renew both repositories UI", inColumn: "In Progress")
        openTask(named: "Renew both repositories UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Renew both repositories UI", prompt: "Change both repositories.")
        element("back-to-board-button").click()
    }
    // case-contract: test_done_archive_displays_existing_pull_request_link | CLI/XPC creates PRs for two repositories, verifies the first PR persists when the second creation fails, retries only the missing repository, confirms each gh create call targets the corresponding repository worktree, and confirms both saved numbers on fresh reads. The UI labels active-card and Done-archive multi-repository creation actions PRs, clicks the active action, verifies the partial-success retry action, confirms the gh create calls target both repository worktrees and retry only the failed one, then shows exact PR numbers on the active task and Done archive, including four-digit values without grouping separators, each with a hit target at least 30 points wide and tall. Hovering the outer padded edge of each PR link triggers its feedback.
    func test_done_archive_displays_existing_pull_request_link() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        // The fixture `gh` handles list/create and merged-state calls without GitHub sign-in.
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Archived linked PR UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--repo", fixture.secondary.path])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Archived linked PR UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Archived linked PR UI")
        element("back-to-board-button").click()
        moveTaskToDone(taskID: taskID)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        element("done-archive-button").click()
        let archiveCreatePRButton = element("done-archive-create-pr-\(taskID)")
        XCTAssertTrue(archiveCreatePRButton.waitToExist(timeout: 10))
        XCTAssertEqual(archiveCreatePRButton.label, "PRs. Create pull requests for each repository linked to this completed task")
        attachScreenshot(named: "Done archive labels its multi-repository action PRs")
        element("close-done-archive-button").click()
        XCTAssertTrue(waitUntil({ !self.element("done-archive-panel").exists }, timeout: 5), "Close the archive before returning to the active task board.")

        let activeCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Active linked PR UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--repo", fixture.secondary.path,
        ])["result"] as? [String: Any])
        let activeTaskID = try XCTUnwrap(activeCreated["id"] as? String)
        // Pinned to Manual: this case drives the manual PR path, and new tasks now start in PR mode.
        try setPullRequestMode("manual", taskID: activeTaskID)
        openTask(named: "Active linked PR UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Active linked PR UI")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "Review")
        XCTAssertTrue(terminateAppAndWait(app), "Close Playhouse before clearing the fixture provider session.")
        try clearTaskProviderSession(taskID: activeTaskID)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let createPRButton = element("task-create-pr-\(activeTaskID)")
        XCTAssertTrue(createPRButton.waitToExist(timeout: 5), "An active repository task should expose its Create PR button.")
        XCTAssertEqual(createPRButton.label, "PRs. Create pull requests for each repository linked to this task")
        revealOnBoard(createPRButton)
        assertHoverEmphasis(for: createPRButton)
        attachScreenshot(named: "Multi-repository task labels its action PRs")
        let records = try XCTUnwrap((try taskRecord(id: activeTaskID)?["repositoryWorktrees"] as? [[String: Any]]))
        let remoteRoot = dataDirectory.appendingPathComponent("multi-pr-remotes", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.path), "Each case must start with isolated PR remotes.")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(to: remoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
        for repository in [fixture.primary, fixture.secondary] {
            XCTAssertFalse(try runGitOutput(repository, "remote").split(whereSeparator: \.isNewline).contains("origin"), "The isolated source fixture must not already have an origin remote.")
        }
        addTeardownBlock { [self] in
            for repository in [fixture.primary, fixture.secondary] {
                try? runGit(repository, "remote", "remove", "origin")
            }
        }
        for (index, record) in records.enumerated() {
            let remote = remoteRoot.appendingPathComponent("repository-\(index).git", isDirectory: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try runGit(remote, "init", "--bare")
            let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String))
            try runGit(worktree, "remote", "add", "origin", remote.path)
            try runGit(worktree, "push", "origin", "main")
            try "Repository \(index) task change.\n".write(to: worktree.appendingPathComponent("task-change.txt"), atomically: true, encoding: .utf8)
        }
        let failurePath = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH"]))
        try "2\n".write(to: failurePath, atomically: true, encoding: .utf8)
        createPRButton.click()
        let partialFailure = app.sheets.firstMatch
        XCTAssertTrue(partialFailure.waitToExist(timeout: 30), "The second repository's configured gh failure should surface in the task.")
        partialFailure.buttons["OK"].click()
        let firstCreatedLink = app.links["task-pr-link-\(activeTaskID)-501"]
        XCTAssertTrue(firstCreatedLink.waitToExist(timeout: 10), "The first repository's successful PR should persist after the second fails.")
        XCTAssertEqual(firstCreatedLink.label, "#501")
        let retryPRButton = element("task-create-pr-\(activeTaskID)")
        XCTAssertTrue(retryPRButton.waitToExist(timeout: 10), "The task should keep a PR action while another repository has no PR.")
        // Only the repository still without a PR is counted, so the retry reads as a single PR.
        XCTAssertEqual(retryPRButton.label, "PR. Create a pull request for the repository without a linked pull request")
        attachScreenshot(named: "Task shows its PR and retry action after partial creation")
        try "\n".write(to: failurePath, atomically: true, encoding: .utf8)
        retryPRButton.click()
        let secondCreatedLink = app.links["task-pr-link-\(activeTaskID)-502"]
        XCTAssertTrue(secondCreatedLink.waitToExist(timeout: 30), "Retry should create a PR for the repository still missing one.")
        XCTAssertEqual(secondCreatedLink.label, "#502")
        let createdTask = try XCTUnwrap(taskRecord(id: activeTaskID))
        let createdRecords = try XCTUnwrap(createdTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(createdRecords.compactMap { $0["pullRequestNumber"] as? Int }, [501, 502])
        let createLog = try String(contentsOfFile: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"]), encoding: .utf8)
        XCTAssertEqual(createLog.components(separatedBy: "\n").filter { $0.hasPrefix("created\t") }.count, 2)
        XCTAssertEqual(createLog.components(separatedBy: "\n").filter { $0.hasPrefix("failed\t") }.count, 1)
        let createTargets = createLog.components(separatedBy: "\n")
            .filter { $0.hasPrefix("create\t") || $0.hasPrefix("failed\t") }
            .compactMap { $0.split(separator: "\t", maxSplits: 2).dropFirst().first.map(String.init) }
            .map { $0.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        let expectedCreateTargets = try [records[0], records[1], records[1]].map {
            URL(fileURLWithPath: try XCTUnwrap($0["worktreePath"] as? String))
                .resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        }
        XCTAssertEqual(createTargets, expectedCreateTargets, "The action should create one PR per repository and retry only the repository whose first create failed.")
        attachScreenshot(named: "Task shows PR numbers for both repositories")

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 10), "The app must close its SwiftData container before seeding the archived store.")
        let activePRURL = "https://github.com/playhouse-test/fixture/pull/1234"
        try seedTaskPullRequest(taskID: activeTaskID, number: 1234, url: activePRURL)
        let prURL = "https://github.com/playhouse-test/fixture/pull/1234"
        let secondPRURL = "https://github.com/playhouse-test/fixture/pull/1235"
        try seedTaskPullRequest(taskID: taskID, number: 1234, url: prURL)
        try seedTaskPullRequest(taskID: taskID, number: 1235, url: secondPRURL, repositoryIndex: 1)
        let persisted = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(persisted["status"] as? String, "Done")
        let record = try XCTUnwrap((persisted["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["pullRequestNumber"] as? Int, 1234)
        XCTAssertEqual(record["pullRequestURL"] as? String, prURL)
        XCTAssertEqual((persisted["repositoryWorktrees"] as? [[String: Any]])?.count, 2)

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let firstActiveLink = app.links["task-pr-link-\(activeTaskID)-1234"]
        let secondActiveLink = app.links["task-pr-link-\(activeTaskID)-502"]
        XCTAssertTrue(firstActiveLink.waitToExist(timeout: 10))
        XCTAssertTrue(secondActiveLink.waitToExist(timeout: 10), "The active task card should show each repository's created PR number.")
        XCTAssertEqual(firstActiveLink.label, "#1234")
        XCTAssertEqual(secondActiveLink.label, "#502")
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitToExist(timeout: 10))
        let prLink = app.links["done-archive-pr-link-\(taskID)-1234"]
        XCTAssertTrue(prLink.waitToExist(timeout: 10), "The Done archive should show the saved PR number as a link.")
        let secondPRLink = app.links["done-archive-pr-link-\(taskID)-1235"]
        XCTAssertTrue(secondPRLink.waitToExist(timeout: 10), "The Done archive should show every repository's saved PR number.")
        XCTAssertEqual(prLink.label, "#1234")
        XCTAssertEqual(secondPRLink.label, "#1235")
        for link in [prLink, secondPRLink] {
            XCTAssertGreaterThanOrEqual(link.frame.width, 30, "A Done archive PR link should have a comfortable horizontal hit target.")
            XCTAssertGreaterThanOrEqual(link.frame.height, 30, "A Done archive PR link should have a comfortable vertical hit target.")
            XCTAssertTrue(link.isHittable, "A Done archive PR link must be reachable at its own position, not resolved to the board under the archive.")
        }
        assertHoverEmphasis(for: prLink)
        attachScreenshot(named: "Done archive shows the linked pull request")
    }
    // case-contract: test_task_pr_create_skips_unchanged_repositories | PR creation opens a pull request only for repositories whose task branch has commits its merge target lacks: in a two-repository task where only the primary worktree changed, gh create runs once, against the primary worktree, the primary saves its PR number on a fresh read, and the unchanged secondary keeps no PR link instead of failing the whole operation with GitHub's no-commits error and is remembered as skipped at its branch head, so the card offers no further create action; a review sync with no change keeps the skip, and once the primary's pull request merges and the task moves to Done, the Done archive shows the primary's PR link and no create action either. A two-repository task whose every repository is unchanged is rejected with a message saying no repository has changes to open a pull request for, with no gh create call and no PR link saved, and both repositories are remembered as skipped. After the task changes one of them, the review sync clears only that repository's skip, the card's create action counts it alone as a single PR, and creating it opens exactly one more pull request, for that repository. A later change to the still-skipped repository beside that linked PR brings back a single create action for the repository without a linked pull request, and creating it links that repository too. The UI shows the primary's PR link after clicking the PRs action and reports the all-unchanged message in the failure alert.
    func test_task_pr_create_skips_unchanged_repositories() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        var taskIDs: [String] = []
        for title in ["Skip unchanged UI", "Nothing to propose UI"] {
            let created = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--repo", fixture.secondary.path,
                "--merge-target", "\(fixture.primary.path)=main", "--merge-target", "\(fixture.secondary.path)=main",
            ])["result"] as? [String: Any])
            let taskID = try XCTUnwrap(created["id"] as? String)
            // Pinned to Manual: this case drives the manual PR path, and new tasks now start in PR mode.
            try setPullRequestMode("manual", taskID: taskID)
            openTask(named: title)
            try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
            element("back-to-board-button").click()
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
            taskIDs.append(taskID)
        }
        let taskID = taskIDs[0]
        let unchangedID = taskIDs[1]
        XCTAssertTrue(terminateAppAndWait(app), "Close Playhouse before clearing the fixture provider sessions.")
        for id in taskIDs { try clearTaskProviderSession(taskID: id) }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        let records = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]]))
        let remoteRoot = dataDirectory.appendingPathComponent("skip-unchanged-remotes", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.path), "Each case must start with isolated PR remotes.")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(to: remoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
        for repository in [fixture.primary, fixture.secondary] {
            XCTAssertFalse(try runGitOutput(repository, "remote").split(whereSeparator: \.isNewline).contains("origin"), "The isolated source fixture must not already have an origin remote.")
        }
        addTeardownBlock { [self] in
            for repository in [fixture.primary, fixture.secondary] {
                try? runGit(repository, "remote", "remove", "origin")
            }
        }
        // Remotes live in the source repositories' shared config, so the second task's worktrees see them too.
        for (index, record) in records.enumerated() {
            let remote = remoteRoot.appendingPathComponent("repository-\(index).git", isDirectory: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try runGit(remote, "init", "--bare")
            let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String))
            try runGit(worktree, "remote", "add", "origin", remote.path)
            try runGit(worktree, "push", "origin", "main")
        }
        let primaryWorktree = URL(fileURLWithPath: try XCTUnwrap(records[0]["worktreePath"] as? String), isDirectory: true)
        let secondaryWorktree = URL(fileURLWithPath: try XCTUnwrap(records[1]["worktreePath"] as? String), isDirectory: true)
        try "Only the primary repository changed.\n".write(to: primaryWorktree.appendingPathComponent("task-change.txt"), atomically: true, encoding: .utf8)

        let createPRButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(createPRButton.waitToExist(timeout: 5), "The two-repository task should expose its PRs action.")
        revealOnBoard(createPRButton)
        createPRButton.click()
        let primaryLink = app.links["task-pr-link-\(taskID)-501"]
        XCTAssertTrue(primaryLink.waitToExist(timeout: 30), "The changed repository should get its pull request.")
        // The only repository without a PR is the unchanged one, so no create action remains.
        XCTAssertTrue(waitUntil({ !createPRButton.exists }, timeout: 30), "The card must not offer a pull request for the unchanged repository.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "An unchanged repository must not fail the PR operation.")
        let createdRecords = try XCTUnwrap(taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(createdRecords[0]["pullRequestNumber"] as? Int, 501)
        XCTAssertNil(createdRecords[1]["pullRequestNumber"], "The unchanged repository must keep no PR link.")
        let secondaryHead = try runGitOutput(secondaryWorktree, "rev-parse", "HEAD")
        XCTAssertEqual(createdRecords[1]["pullRequestSkippedHead"] as? String, secondaryHead, "The unchanged repository must be remembered as skipped.")
        let createLogPath = try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"])
        func createTargets() throws -> [String] {
            try String(contentsOfFile: createLogPath, encoding: .utf8).components(separatedBy: "\n")
                .filter { $0.hasPrefix("create\t") }
                .compactMap { $0.split(separator: "\t", maxSplits: 2).dropFirst().first.map(String.init) }
                .map { $0.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        }
        func normalized(_ url: URL) -> String { url.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        XCTAssertEqual(try createTargets(), [normalized(primaryWorktree)], "gh create must run only for the changed repository.")
        attachScreenshot(named: "Only the changed repository gets a pull request")

        // The review sync keeps the skip while the repository stays unchanged.
        XCTAssertEqual(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["ok"] as? Bool, true)
        XCTAssertEqual((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?[1]["pullRequestSkippedHead"] as? String, secondaryHead)
        XCTAssertFalse(waitUntil({ createPRButton.exists }, timeout: 3), "A sync with no change must keep the create action hidden.")

        // The Done archive reads the same skip, so it offers no create action either.
        try "501=merged\n".write(toFile: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]), atomically: true, encoding: .utf8)
        revealOnBoard(element("task-card-\(taskID)"))
        moveTaskToDone(taskID: taskID)
        element("done-archive-button").click()
        XCTAssertTrue(app.links["done-archive-pr-link-\(taskID)-501"].waitToExist(timeout: 10), "The archived task should show its pull request.")
        XCTAssertFalse(element("done-archive-create-pr-\(taskID)").exists, "The archive must not offer a pull request for the unchanged repository.")
        attachScreenshot(named: "Done archive offers no PR for the unchanged repository")
        // The open archive panel covers the Review column, so close it before using the board.
        element("close-done-archive-button").click()
        XCTAssertTrue(waitUntil({ !self.app.scrollViews["done-archive-list"].exists }, timeout: 10), "The Done archive should close before the board is used again.")

        // A task whose every repository is unchanged explains why no pull request was opened.
        let unchangedButton = element("task-create-pr-\(unchangedID)")
        XCTAssertTrue(unchangedButton.waitToExist(timeout: 10))
        XCTAssertEqual(unchangedButton.label, "PRs. Create pull requests for each repository linked to this task")
        revealOnBoard(unchangedButton)
        unchangedButton.click()
        let alertSheet = app.sheets.firstMatch
        XCTAssertTrue(alertSheet.waitToExist(timeout: 30), "A task with no changes should report why no pull request was opened.")
        XCTAssertTrue(waitUntil({
            self.element(containingAccessibilityText: "No repository in this task has changes").exists
        }, timeout: 5), app.debugDescription)
        attachScreenshot(named: "A task with no changes explains why no pull request was opened")
        alertSheet.buttons["OK"].click()
        let skipped = try XCTUnwrap(try taskRecord(id: unchangedID)?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertTrue(skipped.allSatisfy { $0["pullRequestNumber"] == nil })
        XCTAssertTrue(skipped.allSatisfy { ($0["pullRequestSkippedHead"] as? String)?.isEmpty == false }, "Both unchanged repositories must be remembered as skipped.")
        XCTAssertEqual(try createTargets().count, 1, "An all-unchanged task must not call gh create.")

        // Once the task changes one repository, the review sync offers that one a single PR.
        let laterWorktree = URL(fileURLWithPath: try XCTUnwrap(skipped[1]["worktreePath"] as? String), isDirectory: true)
        try "The secondary repository changed later.\n".write(to: laterWorktree.appendingPathComponent("later-change.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try runCLI(["task", "pr", "sync", unchangedID], extraEnvironment: ghEnvironment)["ok"] as? Bool, true)
        let singleLabel = "PR. Create a pull request for each repository linked to this task"
        XCTAssertTrue(waitUntil({ unchangedButton.exists && unchangedButton.label == singleLabel }, timeout: 30), "Only the changed repository should count toward the PR action.")
        let reopened = try XCTUnwrap(try taskRecord(id: unchangedID)?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(reopened[0]["pullRequestSkippedHead"] as? String, skipped[0]["pullRequestSkippedHead"] as? String, "The still-unchanged repository stays skipped.")
        XCTAssertNil(reopened[1]["pullRequestSkippedHead"], "A changed repository must await a pull request again.")
        attachScreenshot(named: "A later change to one skipped repository offers a single PR")
        revealOnBoard(unchangedButton)
        unchangedButton.click()
        XCTAssertTrue(app.links["task-pr-link-\(unchangedID)-502"].waitToExist(timeout: 30), "The later-changed repository should get its pull request.")
        XCTAssertTrue(waitUntil({ !unchangedButton.exists }, timeout: 30), "Every changed repository has a pull request, so no create action remains.")
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertEqual(try createTargets(), [normalized(primaryWorktree), normalized(laterWorktree)], "The later change must open exactly one more pull request, for the changed repository.")
        attachScreenshot(named: "Only the later-changed repository gets the new pull request")

        // Beside a linked PR, a later change to the still-skipped repository brings back a single PR action.
        let laterPrimaryWorktree = URL(fileURLWithPath: try XCTUnwrap(skipped[0]["worktreePath"] as? String), isDirectory: true)
        try "The primary repository changed later.\n".write(to: laterPrimaryWorktree.appendingPathComponent("later-change.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try runCLI(["task", "pr", "sync", unchangedID], extraEnvironment: ghEnvironment)["ok"] as? Bool, true)
        XCTAssertTrue(unchangedButton.waitToExist(timeout: 30), "A repository changed beside a linked PR should be offered a pull request again.")
        XCTAssertEqual(unchangedButton.label, "PR. Create a pull request for the repository without a linked pull request")
        XCTAssertTrue(app.links["task-pr-link-\(unchangedID)-502"].exists)
        attachScreenshot(named: "A later change beside a linked PR offers a single PR")
        revealOnBoard(unchangedButton)
        unchangedButton.click()
        XCTAssertTrue(app.links["task-pr-link-\(unchangedID)-503"].waitToExist(timeout: 30), "The repository changed beside a linked PR should get its pull request.")
        XCTAssertTrue(waitUntil({ !unchangedButton.exists }, timeout: 30), "Both repositories now have pull requests, so no create action remains.")
        XCTAssertEqual(try createTargets(), [normalized(primaryWorktree), normalized(laterWorktree), normalized(laterPrimaryWorktree)])
    }
    // case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    func test_task_lifecycle_rollout_clears_records_and_clean_worktrees() throws {
        _ = try runCLI(["settings", "set-parent", fixture.parent.path])
        let clean = try runCLI(["task", "create", "--title", "Rollout clean", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        let dirty = try runCLI(["task", "create", "--title", "Rollout dirty", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path])
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let cleanTaskID = try XCTUnwrap((clean["result"] as? [String: Any])?["id"] as? String)
        let dirtyTaskID = try XCTUnwrap((dirty["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", cleanTaskID, "--message", "Materialize the clean worktree.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
        _ = try runCLI(["conversation", "send", dirtyTaskID, "--message", "Materialize the dirty worktree.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
        let cleanResult = try XCTUnwrap(try runCLI(["task", "get", cleanTaskID])["result"] as? [String: Any])
        let dirtyResult = try XCTUnwrap(try runCLI(["task", "get", dirtyTaskID])["result"] as? [String: Any])
        let cleanRecord = try XCTUnwrap((cleanResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let dirtyRecord = try XCTUnwrap((dirtyResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        let dirtyPath = try XCTUnwrap(dirtyRecord["worktreePath"] as? String)
        let cleanBranch = try XCTUnwrap(cleanRecord["branch"] as? String)
        let dirtyBranch = try XCTUnwrap(dirtyRecord["branch"] as? String)
        let retainedFile = URL(fileURLWithPath: dirtyPath).appendingPathComponent("playhouse-secondary.txt")
        try "Secondary baseline.\nKeep this worktree.\n".write(to: retainedFile, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("task-lifecycle-v2-reset"))

        launchApp(defaultParent: fixture.parent.path)
        let resetNotice = element("task-lifecycle-reset-notice")
        let resetDetails = element("task-lifecycle-reset-details")
        XCTAssertTrue(resetNotice.waitToExist(timeout: 10), app.debugDescription)
        XCTAssertTrue(element("task-lifecycle-reset-title").exists)
        XCTAssertTrue(accessibleLabelOrValue(of: resetDetails).contains(dirtyPath), app.debugDescription)
        element("dismiss-task-lifecycle-reset-notice").click()
        XCTAssertNil(try taskRecord(named: "Rollout clean"))
        XCTAssertNil(try taskRecord(named: "Rollout dirty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertEqual(try String(contentsOf: retainedFile, encoding: .utf8), "Secondary baseline.\nKeep this worktree.\n")
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(cleanBranch)")
        try runGit(fixture.secondary, "show-ref", "--verify", "--quiet", "refs/heads/\(dirtyBranch)")
        attachScreenshot(named: "Lifecycle rollout clears tasks and reports a retained dirty worktree")
    }
    // case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, washes only the Waiting Response column in its purple tint (its pixels read purple where the other columns read neutral), allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status; ⌘F reveals and focuses a prominent board search that filters task cards by title as text changes, while close restores all cards. Answering a question without an explicit completed outcome leaves the task in Waiting Response. Task card titles use slightly expanded letter spacing and line spacing. The board's columns stay centered and clickable where they draw after a sideways scroll followed by a new card, without needing a window resize. The board's scroller stays hidden until the pointer is over the board, then shows at a subdued opacity while the pointer rests there, and hides again once the pointer leaves; holding its knob makes it clearly more opaque than the same knob hovered, and releasing returns it to the subdued opacity. Each board column is built from plugin atoms: the empty In Progress and Review columns show their empty state while the populated Backlog does not, and the Backlog's Add button opens a new task conversation.
    func test_task_status_transitions_and_rejects_unknown_status() throws {
        let waitingFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-status-transition-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: waitingFixture.path))
        codexFixtureExecutable = waitingFixture.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Status transitions", roots: [fixture.primary.path])
        try createTaskFixture(title: "Searchable board card", roots: [fixture.alternate.path])
        let titleElement = app.staticTexts["Searchable board card"]
        XCTAssertTrue(titleElement.waitToExist(timeout: 5), "The task card should expose its rendered title text.")
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let untrackedWidth = ("Searchable board card" as NSString).size(withAttributes: [.font: titleFont]).width
        XCTAssertGreaterThan(
            titleElement.frame.width,
            untrackedWidth + 2,
            "The title's rendered width should reflect the added letter spacing."
        )
        let wrappedTitle = "Task card title spacing increases between wrapped lines"
        try createTaskFixture(title: wrappedTitle, roots: [fixture.alternate.path])
        let wrappedTitleElement = app.staticTexts[wrappedTitle]
        XCTAssertTrue(wrappedTitleElement.waitToExist(timeout: 5))
        let wrappedTitleBaseline = NSAttributedString(
            string: wrappedTitle,
            attributes: [.font: titleFont, .kern: 0.35]
        ).boundingRect(
            with: CGSize(width: wrappedTitleElement.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        XCTAssertGreaterThan(
            wrappedTitleElement.frame.height,
            wrappedTitleBaseline + 1,
            "Wrapped task titles should have visible spacing between lines."
        )
        XCTAssertFalse(element("board-search-field").exists, "Board search should stay hidden until requested.")
        XCTAssertFalse(element("task-count").exists, "The top bar should not show a task counter.")
        XCTAssertFalse(element("board-search-button").exists, "The top bar should not show a search button; search is keyboard-only.")
        app.typeKey("f", modifierFlags: .command)
        let boardSearch = element("board-search-field")
        XCTAssertTrue(boardSearch.waitToExist(timeout: 5), "Command+F should reveal the prominent board search.")
        XCTAssertLessThan(element("board-search-bar").frame.maxY, element("board-columns-scroll-view").frame.minY, "Board search should sit above the task columns.")
        boardSearch.typeText("Searchable")
        XCTAssertTrue(app.buttons["Searchable board card"].waitToExist(timeout: 5))
        XCTAssertFalse(app.buttons["Status transitions"].exists, "Nonmatching task cards should be filtered out.")
        element("close-board-search-button").click()
        XCTAssertFalse(element("board-search-field").exists)
        XCTAssertTrue(app.buttons["Status transitions"].exists)
        XCTAssertTrue(app.buttons["Searchable board card"].exists)
        let columns = ["backlog", "in-progress", "review"]
        for column in columns { XCTAssertTrue(element("column-heading-\(column)").exists, "Missing \(column) board column.") }
        XCTAssertFalse(element("column-heading-done").exists, "Done tasks should live in the archive, not a board column.")
        XCTAssertFalse(element("column-heading-waiting-response").exists, "Waiting Response should be hidden when no tasks are waiting.")
        let inProgressColumn = element("column-in-progress")
        let reviewColumn = element("column-review")
        let boardViewport = element("board-columns-scroll-view")
        XCTAssertLessThan(inProgressColumn.frame.maxX, reviewColumn.frame.minX, "Review should remain a separate column after the stacked pair.")
        XCTAssertLessThanOrEqual(inProgressColumn.frame.maxY, boardViewport.frame.maxY, "In Progress should fit inside the visible board area.")
        XCTAssertLessThanOrEqual(reviewColumn.frame.maxY, boardViewport.frame.maxY, "Review should fit inside the visible board area.")
        XCTAssertFalse(element("column-heading-blocked").exists, "The blocked section should be hidden when no tasks are blocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
        XCTAssertFalse(element("column-heading-ready").exists)
        XCTAssertTrue(element("empty-state-in-progress").exists, "An empty column shows its empty state.")
        XCTAssertTrue(element("empty-state-review").exists, "An empty Review column shows its empty state.")
        XCTAssertFalse(element("empty-state-backlog").exists, "A column with tasks has no empty state.")
        XCTAssertTrue(element("add-backlog-task-button").exists, "Only the Backlog column has an Add button.")
        assertTaskVisible("Status transitions", inColumn: "Backlog")

        let statusTaskID = try taskID(named: "Status transitions")
        assertCLIError(try runCLI(["task", "move", statusTaskID, "Unknown"], expectedStatus: 2), code: "invalid_argument")
        for status in ["In Progress", "Blocked", "Waiting Response", "Review", "Done", "Backlog"] {
            assertCLIError(try runCLI(["task", "move", statusTaskID, status], expectedStatus: 2), code: "invalid_argument")
        }
        XCTAssertEqual(try taskRecord(named: "Status transitions")?["status"] as? String, "Backlog")
        assertTaskVisible("Status transitions", inColumn: "Backlog")

        let blockedTask = try runCLI(["task", "create", "--title", "Blocked layout", "--prompt", "Fixture task description.", "--root", fixture.secondary.path])
        let blockedTaskID = try XCTUnwrap((blockedTask["result"] as? [String: Any])?["id"] as? String)
        let emptyFixture = try makeCodexFixture(emptyQuestions: true)
        assertCLIError(
            try runCLI(
                ["conversation", "send", blockedTaskID, "--message", "Please ask your questions."],
                expectedStatus: 1,
                extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": emptyFixture.path]
            ),
            code: "operation_failed"
        )
        XCTAssertEqual(try taskRecord(id: blockedTaskID)?["status"] as? String, "Blocked")

        try createTaskFixture(title: "In Progress layout", roots: [fixture.alternate.path])
        let activeTaskID = try taskID(named: "In Progress layout")
        let activeExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-progress-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: activeExecutable.path))
        let activeTurn = try startProgressFixtureTurn(taskID: activeTaskID, executable: activeExecutable)
        defer {
            if activeTurn.process.isRunning {
                try? "Release the active turn.\n".write(to: activeTurn.releaseMarker, atomically: true, encoding: .utf8)
                activeTurn.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeTurn.activeMarker)
            try? FileManager.default.removeItem(at: activeTurn.releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeTurn.activeMarker.path) }, timeout: 10))
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "In Progress")

        try createTaskFixture(title: "Waiting layout", roots: [fixture.secondary.path])
        let waitingTaskID = try taskID(named: "Waiting layout")
        openTask(named: "Waiting layout")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))

        assertTaskVisible("Blocked layout", inColumn: "Blocked")
        assertTaskVisible("Status transitions", inColumn: "Backlog")
        assertTaskVisible("Waiting layout", inColumn: "Waiting Response")
        assertTaskVisible("In Progress layout", inColumn: "In Progress")
        XCTAssertTrue(element("column-heading-blocked").exists)
        XCTAssertTrue(element("column-heading-waiting-response").exists)
        XCTAssertTrue(element("blocked-waiting-indicator").exists)
        let blockedColumn = element("column-blocked")
        let backlogColumn = element("column-backlog")
        let waitingResponseColumn = element("column-waiting-response")
        let waitingResponseTint = try columnPurpleness(waitingResponseColumn, visibleIn: boardViewport)
        // Review runs past the viewport's right edge; these columns' tops are in view.
        for key in ["blocked", "backlog", "in-progress"] {
            let neutral = try columnPurpleness(element("column-\(key)"), visibleIn: boardViewport)
            XCTAssertGreaterThan(waitingResponseTint, neutral + 0.012, "Only the Waiting Response column is washed purple, not \(key) (\(waitingResponseTint) vs \(neutral)).")
        }
        XCTAssertLessThan(blockedColumn.frame.maxY, backlogColumn.frame.minY, "Blocked should remain stacked above Backlog.")
        XCTAssertLessThan(waitingResponseColumn.frame.maxY, inProgressColumn.frame.minY, "Waiting Response should remain stacked above In Progress.")
        for topColumn in [blockedColumn, waitingResponseColumn] {
            XCTAssertGreaterThanOrEqual(topColumn.frame.minY, boardViewport.frame.minY)
        }
        // Lower backlog tasks are reached by scrolling the board; each column starts in view.
        for bottomColumn in [backlogColumn, inProgressColumn, reviewColumn] {
            XCTAssertLessThan(bottomColumn.frame.minY, boardViewport.frame.maxY)
        }
        XCTAssertLessThan(inProgressColumn.frame.maxX, reviewColumn.frame.minX, "Review should remain a separate column after the stacked pair.")
        XCTAssertFalse(element("column-heading-done").exists, "Done tasks should remain outside the board columns.")
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "In Progress")
        attachScreenshot(named: "Blocked and Waiting Response stacks fit with their active columns and Review")

        let blockedCard = element("task-card-\(blockedTaskID)")
        blockedCard.rightClick()
        XCTAssertTrue(element("rename-task-menu-item").waitToExist(timeout: 5), "Stacked columns should retain full task-card actions.")
        XCTAssertTrue(element("delete-task-menu-item").exists)
        app.typeKey(.escape, modifierFlags: [])

        openTask(named: "Waiting layout")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 5))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Waiting layout", inColumn: "Waiting Response")

        // This task exists for board layout, so it settles explicitly rather than
        // depending on the status-nudge fallback that other cases own.
        XCTAssertEqual(
            (try runCLI(["task", "outcome", activeTaskID, "waiting-response"])["result"] as? [String: Any])?["outcome"] as? String,
            "waiting-response"
        )
        try "Release the active turn.\n".write(to: activeTurn.releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !activeTurn.process.isRunning }, timeout: 30), "The In Progress fixture conversation should finish once released.")
        activeTurn.process.waitUntilExit()
        let activeOutput = String(data: activeTurn.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let activeError = String(data: activeTurn.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(activeTurn.process.terminationStatus, 0, "The In Progress fixture turn should complete: \(activeOutput) \(activeError)")
        let activeResponseLine = try XCTUnwrap(activeOutput.split(whereSeparator: \.isNewline).last)
        let activeResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(activeResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(activeResponse["ok"] as? Bool == true)
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "Waiting Response")
        assertTaskVisible("In Progress layout", inColumn: "Waiting Response")

        for index in 1...12 {
            try createTaskFixture(title: "Backlog scroll \(index)", roots: [fixture.primary.path])
        }
        let lowestTask = app.buttons["Backlog scroll 1"]
        XCTAssertFalse(lowestTask.isHittable, "The final backlog task should begin below the board viewport.")
        for _ in 0..<20 where !lowestTask.isHittable {
            boardViewport.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(waitUntil({ lowestTask.exists && lowestTask.isHittable }, timeout: 10), "Vertical board scrolling should make lower backlog tasks reachable.")

        // The columns are narrower than the window, so the board centers them. A sideways
        // scroll nudge followed by a content-height change used to leave hit testing flush
        // left while the columns still drew centered, so clicks missed every card and button
        // until the window was resized.
        // The newest card lands at the top, so start there; any later vertical scroll would
        // re-sync the stale geometry and hide the regression.
        let newestBacklogTask = app.buttons["Backlog scroll 12"]
        for _ in 0..<20 where !newestBacklogTask.isHittable {
            boardViewport.scroll(byDeltaX: 0, deltaY: 300)
        }
        XCTAssertTrue(waitUntil({ newestBacklogTask.isHittable }, timeout: 10), "Scrolling up should return to the top of the backlog.")
        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.exists)
        let centeredBacklogMinX = backlogColumn.frame.minX
        XCTAssertGreaterThan(centeredBacklogMinX - mainWindow.frame.minX, 40, "The window is wider than the columns, so they should sit centered: backlog=\(backlogColumn.frame), window=\(mainWindow.frame).")
        boardViewport.scroll(byDeltaX: -120, deltaY: 0)
        boardViewport.scroll(byDeltaX: 120, deltaY: 0)
        try createTaskFixture(title: "Backlog after nudge", roots: [fixture.primary.path])
        let nudgedTask = app.buttons["Backlog after nudge"]
        XCTAssertTrue(waitUntil({ nudgedTask.exists && nudgedTask.isHittable }, timeout: 10), "The new backlog card should appear at the top of the column.")
        XCTAssertTrue(waitUntil({ abs(backlogColumn.frame.minX - centeredBacklogMinX) <= 4 }, timeout: 3), "A sideways nudge and a new card should not move the board's hit-test layout away from where it draws: backlog=\(backlogColumn.frame), expected minX=\(centeredBacklogMinX).")
        attachScreenshot(named: "Centered board after a sideways nudge and a new card: columns stay where they draw")
        // Click near the card's drawn trailing edge, derived from the centered layout
        // rather than its current accessibility frame, so a stale hit-test layout
        // (shifted toward the leading edge) would miss the card.
        let cardTrailingInset = nudgedTask.frame.maxX - backlogColumn.frame.minX
        let drawnCardPoint = CGPoint(x: centeredBacklogMinX + cardTrailingInset - 12, y: nudgedTask.frame.midY)
        mainWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: drawnCardPoint.x - mainWindow.frame.minX, dy: drawnCardPoint.y - mainWindow.frame.minY))
            .click()
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10), "Clicking the card where it draws should open the task.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        // Last, since holding the scroller's knob scrolls the board, which the click above must not see.
        let boardTitle = element("board-title")
        try assertScrollerRevealsOnlyOnHover(boardViewport, elsewhere: boardTitle, named: "board")
        // Holding the knob raises it to full opacity, and releasing it returns it to the subdued
        // opacity. AppKit widens a scroller under the pointer, so the knob is compared with itself
        // hovered but not held, after the drag, where every capture shares the same scroll offset.
        let boardScroller = try verticalScroller(of: boardViewport)
        let boardScrollerStrip = boardScroller.frame.intersection(boardViewport.frame)
        func boardKnob() -> XCUIElement { boardScroller.descendants(matching: .valueIndicator).firstMatch }
        boardViewport.hover()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(boardKnob().exists, "The board scroller should expose its knob.")
        let knob = boardKnob().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        knob.hover()
        Thread.sleep(forTimeInterval: 1)
        // The press-drag-hold below blocks while it runs, but it spins the main run loop, so a
        // timer captures the screen while the knob is held. (`screencapture` can't read the
        // display in the UI VM.)
        var heldScreenshot: XCUIScreenshot?
        let heldTimer = Timer(timeInterval: 2, repeats: false) { _ in heldScreenshot = XCUIScreen.main.screenshot() }
        RunLoop.main.add(heldTimer, forMode: .common)
        knob.press(forDuration: 0.3, thenDragTo: knob.withOffset(CGVector(dx: 0, dy: 40)), withVelocity: .default, thenHoldForDuration: 3.5)
        heldTimer.invalidate()
        let heldShot = try XCTUnwrap(heldScreenshot, "The screen should be captured while the knob is held.")
        let heldAttachment = XCTAttachment(screenshot: heldShot)
        heldAttachment.name = "Board scroller knob held: fully opaque"
        heldAttachment.lifetime = .keepAlways
        add(heldAttachment)
        let held = try luminance(in: boardScrollerStrip, of: screenBitmap(heldShot))
        Thread.sleep(forTimeInterval: 1)
        let released = try luminance(in: boardScrollerStrip, of: captureScreenBitmap())
        boardTitle.hover()
        Thread.sleep(forTimeInterval: 2)
        let hiddenAfterDrag = try luminance(in: boardScrollerStrip, of: captureScreenBitmap())
        boardKnob().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 2)
        let knobHovered = try luminance(in: boardScrollerStrip, of: captureScreenBitmap())
        attachScreenshot(named: "Board scroller knob hovered but not held: subdued")
        let heldChange = largestLuminanceChange(hiddenAfterDrag, held)
        let knobHoveredChange = largestLuminanceChange(hiddenAfterDrag, knobHovered)
        XCTAssertGreaterThan(knobHoveredChange, 0.06, "Hovering the knob should show the scroller (change \(knobHoveredChange)).")
        XCTAssertGreaterThan(heldChange, knobHoveredChange * 1.5, "A held knob should be clearly more opaque than the same knob hovered (held \(heldChange), hovered \(knobHoveredChange)).")
        let releaseChange = largestLuminanceChange(knobHovered, released)
        XCTAssertLessThan(releaseChange, 0.05, "Releasing the knob should return it to the subdued opacity (change \(releaseChange)).")
        let addBacklogTask = element("add-backlog-task-button")
        for _ in 0..<20 where !addBacklogTask.isHittable {
            boardViewport.scroll(byDeltaX: 0, deltaY: 300)
        }
        element("add-backlog-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10), "The Backlog's Add button should open a new task conversation.")
    }
}

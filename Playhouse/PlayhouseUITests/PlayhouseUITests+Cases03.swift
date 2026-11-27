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
    // case-contract: test_task_done_removes_worktree_and_preserves_branch | Sending the first message derives an auto branch from the generated task title, with a prompt fallback when title generation fails. Every linked PR must be merged before the task can move to Done. App focus checks each linked PR no more than once per 20 seconds; rapid focus changes are coalesced into one refresh after the cooldown. An unmerged PR keeps its link and suppresses the completion button. PR links and the green completion button have hit targets of at least 30×30 points. After all PRs merge, a later focus check replaces their links with a green completion button; clicking it waits for the task lock and then trusts that already-confirmed merge state, moving the task to Done immediately without re-querying GitHub even if merge status changed while the lock was held. The CLI's task move command has no such cached state, so it always verifies merge status directly with GitHub before completing, including rechecking after waiting for a contended task lock, and reports unmerged pull requests instead of completing when a PR is not actually merged. Completion removes managed worktrees while preserving their branches, does not merge into the local target, retains conversation history, and exposes the task in the searchable archive, whose conversation keeps its composer for follow-up questions; the CLI and the visible archive search the task's stored transcript, matching both the user's prompts and the assistant's replies case-insensitively; the visible archive loads the newest 40 first, and reveals older tasks as the user scrolls. While only some linked PRs are merged, each merged PR's number shows in merged purple and the task offers no completion checkmark until all are merged. The archive slides in from the board header's archive button as a 340-point SidePanel atom (done-archive-panel) along the window's trailing edge, and its close button slides it away until the button opens it again.
    func test_task_done_removes_worktree_and_preserves_branch() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture().merging(Self.prCheckCooldownEnvironment) { $1 }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10), "New Task should open the composer in its conversation.")
        let task = try XCTUnwrap(tasksFromBoardList().first)
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        var path = try XCTUnwrap(record["worktreePath"] as? String)
        var branch = try XCTUnwrap(record["branch"] as? String)
        let taskID = try XCTUnwrap(task["id"] as? String)
        _ = try runCLI(["task", "repository", "add-batch", taskID, "--repo", fixture.secondary.path])
        XCTAssertEqual((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(branch, "auto")
        XCTAssertEqual(record["isPending"] as? Bool, true)
        XCTAssertEqual(path, fixture.primary.path)
        let taskPrompt = "Please update the README and add concise setup steps for first time contributors tomorrow."
        let generatedBranch = "generated-fixture-title"
        XCTAssertNil(record["mergeTarget"], "A pending repository's merge target is undecided until its settings open or the task starts.")
        let composer = element("message-composer")
        let composerIsAvailable = waitUntil({ composer.exists && composer.isHittable }, timeout: 15)
        if !composerIsAvailable {
            attachScreenshot(named: "Unavailable composer after repository selection")
        }
        XCTAssertTrue(composerIsAvailable, "The composer should become available after conversation history loads. enabled=\(composer.isEnabled), value=\(composer.value as? String ?? "<none>"), hittable=\(composer.isHittable), frame=\(composer.frame); \(app.debugDescription)")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Untitled task", prompt: taskPrompt)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        let startedRecord = try XCTUnwrap((taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(startedRecord["isPending"] as? Bool, false)
        path = try XCTUnwrap(startedRecord["worktreePath"] as? String)
        branch = try XCTUnwrap(startedRecord["branch"] as? String)
        XCTAssertNotEqual(path, fixture.primary.path)
        let startedTask = try taskRecord(id: taskID) ?? [:]
        XCTAssertTrue(
            branch == generatedBranch || (branch.hasPrefix(generatedBranch + "-") && branch.count == generatedBranch.count + 5),
            "Auto branch must use the generated title (plus a suffix when taken); task=\(startedTask)"
        )
        let codexHistoryURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let codexHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: codexHistoryURL)) as? [String: Any])
        XCTAssertEqual(codexHistory["threadStartCwd"] as? String, path, "Codex thread startup must use the managed worktree as cwd.")
        let turnHistory = try XCTUnwrap((codexHistory["turns"] as? [[String: Any]])?.first)
        XCTAssertEqual(turnHistory["cwd"] as? String, path, "The user turn must use the managed worktree as cwd.")
        let activeWorktreePaths = try XCTUnwrap(taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]]).compactMap { $0["worktreePath"] as? String }
        XCTAssertEqual(turnHistory["runtimeWorkspaceRoots"] as? [String], activeWorktreePaths)
        let taskBranchHead = try runGitOutput(URL(fileURLWithPath: path), "rev-parse", "HEAD")
        let originalTargetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        XCTAssertEqual(taskBranchHead, originalTargetHead)
        try "Master advanced after this task branch was created.\n".write(
            to: fixture.primary.appendingPathComponent("target-only.txt"), atomically: true, encoding: .utf8
        )
        try runGit(fixture.primary, "add", "target-only.txt")
        try runGit(fixture.primary, "commit", "-m", "Advance merge target while task is under review")
        let targetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        element("back-to-board-button").click()
        let titleDeadline = Date().addingTimeInterval(20)
        var currentTitle = "Generating title…"
        while Date() < titleDeadline, currentTitle == "Generating title…" {
            currentTitle = try XCTUnwrap(taskRecord(id: taskID)?["title"] as? String)
            if currentTitle == "Generating title…" { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        }
        XCTAssertNotEqual(currentTitle, "Generating title…", "The title placeholder should eventually resolve.")
        XCTAssertTrue(terminateAppAndWait(app), "Close Playhouse before seeding the real task-store fixture.")
        try seedTaskPullRequest(
            taskID: taskID,
            number: 123,
            url: "https://github.com/playhouse-test/fixture/pull/123"
        )
        try seedTaskPullRequest(
            taskID: taskID,
            number: 456,
            url: "https://github.com/playhouse-test/fixture/pull/456",
            repositoryIndex: 1
        )
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let prLink = element("task-pr-link-\(taskID)-123")
        let secondPRLink = element("task-pr-link-\(taskID)-456")
        XCTAssertTrue(prLink.waitToExist(timeout: 10), "The linked unmerged PR should remain available on the Review card.")
        XCTAssertTrue(secondPRLink.waitToExist(timeout: 10), "The task's second linked PR should also be visible.")
        XCTAssertGreaterThanOrEqual(prLink.frame.width, 30, "A PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(prLink.frame.height, 30, "A PR link should have a comfortable vertical hit target.")
        XCTAssertGreaterThanOrEqual(secondPRLink.frame.width, 30, "The second PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(secondPRLink.frame.height, 30, "The second PR link should have a comfortable vertical hit target.")
        let completionButton = element("task-complete-merged-pr-\(taskID)")
        XCTAssertFalse(completionButton.exists)
        let ghCallsURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CALL_LOG"]))
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= 2
        }, timeout: 10), "Opening the board should check the linked PR.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertTrue(prLink.exists, "An unmerged PR should stay as a link.")
        XCTAssertTrue(secondPRLink.exists, "A second unmerged PR should stay as a link.")
        Thread.sleep(forTimeInterval: Self.prCheckCooldown + 0.1)
        let ghStateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        try "123=merged\n456=unmerged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        let previousCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= previousCheckCount + 2
        }, timeout: 25), "Regaining focus should refresh the PR merge state.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertFalse(completionButton.exists, "The task should remain incomplete while any linked PR is unmerged.")
        XCTAssertTrue(prLink.exists)
        XCTAssertTrue(secondPRLink.exists)
        XCTAssertTrue(waitUntil({ (prLink.value as? String) == "merged" }, timeout: 10), "The merged PR number should turn purple while its sibling is open.")
        XCTAssertEqual(secondPRLink.value as? String, "green", "The open PR keeps its check colour.")
        attachScreenshot(named: "One of two PRs merged: its number is purple, no checkmark yet", fullScreen: true)
        let rapidFocusCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        for _ in 0..<4 {
            activateOtherAppThenReturn()
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual((try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count, rapidFocusCheckCount, "Rapid focus changes should not repeat GitHub checks.")
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) == rapidFocusCheckCount + 2
        }, timeout: 25), "A focus check suppressed during cooldown should run once after the cooldown.")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual((try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count, rapidFocusCheckCount + 2, "Multiple cooldown focus changes should produce exactly one trailing refresh.")
        Thread.sleep(forTimeInterval: Self.prCheckCooldown + 0.1)
        try "123=merged\n456=merged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        let thirdCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= thirdCheckCount + 2
        }, timeout: 10), "Regaining focus should refresh both PR merge states.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertTrue(completionButton.waitToExist(timeout: 10), "A merged PR should replace its link with the completion button.")
        revealOnBoard(completionButton)
        XCTAssertGreaterThanOrEqual(completionButton.frame.width, 30, "The completion action should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(completionButton.frame.height, 30, "The completion action should have a comfortable vertical hit target.")
        XCTAssertEqual(completionButton.label, "Green checkmark. Complete task, all linked pull requests merged")
        assertContainsGreenForeground(in: completionButton)
        XCTAssertFalse(prLink.exists)
        XCTAssertFalse(secondPRLink.exists)
        let moveLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var moveLockReleased = false
        defer { if !moveLockReleased { try? moveLock.release() } }
        let taskCard = element("task-card-\(taskID)")
        XCTAssertTrue(taskCard.waitToExist(timeout: 5))
        completionButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "The UI move should wait while another process owns the task operation lock.")
        try "123=merged\n456=unmerged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        try moveLock.release()
        moveLockReleased = true
        XCTAssertTrue(waitUntil({ !element("task-card-\(taskID)").exists }, timeout: 15), "The completed task should disappear from the active board.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done", "Completion should trust the already-confirmed merge state and complete without rechecking GitHub, even though merge status changed to unmerged while the click waited for the task lock.")
        // The sent prompt is history, not a draft, and completion keeps the conversation.
        let completedHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertTrue((completedHistory["messages"] as? [[String: Any]] ?? []).contains { $0["role"] as? String == "user" && $0["text"] as? String == taskPrompt })
        XCTAssertEqual(try runCLI(["task", "move", taskID, "Done"])["ok"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Moving a task to Done must remove its managed worktree.")
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead, "Moving a task to Done must not merge into the local target.")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("target-only.txt"), encoding: .utf8), "Master advanced after this task branch was created.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.primary.appendingPathComponent("task-result.txt").path))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")

        let archiveFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-archive-ui").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: archiveFixtureExecutable))
        for index in 1...39 {
            let filler = try XCTUnwrap(try runCLI(["task", "create", "--title", "Archive page filler \(index)", "--prompt", "Fixture task description.", "--root", fixture.custom.path])["result"] as? [String: Any])
            let fillerID = try XCTUnwrap(filler["id"] as? String)
            _ = try runCLI(
                ["conversation", "send", fillerID, "--message", "Echo the outcome command for \(fillerID).", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
                extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": archiveFixtureExecutable]
            )
            XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", fillerID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")
        }
        let titleMatch = try XCTUnwrap(try runCLI(["task", "create", "--title", "fixture-secret title match", "--prompt", "Fixture task description.", "--root", fixture.custom.path])["result"] as? [String: Any])
        let titleMatchID = try XCTUnwrap(titleMatch["id"] as? String)
        _ = try runCLI(
            ["conversation", "send", titleMatchID, "--message", "Echo the outcome command for \(titleMatchID).", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": archiveFixtureExecutable]
        )
        XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", titleMatchID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")

        let archiveButton = element("done-archive-button")
        archiveButton.click()
        let archiveResult = element("done-archive-task-\(taskID)")
        XCTAssertTrue(element("done-archive-task-\(titleMatchID)").waitToExist(timeout: 10), "The newest completed task should appear in the first archive page.")
        let archiveList = app.scrollViews["done-archive-list"]
        XCTAssertEqual(archiveList.value as? String, "40 tasks loaded", "The archive should fetch one 40-task page initially.")
        XCTAssertFalse(archiveResult.exists, "Older tasks should not be loaded into the first archive page.")
        for _ in 0..<8 {
            guard !archiveResult.isHittable else { break }
            archiveList.swipeUp()
        }
        XCTAssertTrue(waitUntil({ archiveResult.isHittable && archiveList.frame.intersects(archiveResult.frame) }, timeout: 10), "Scrolling should load older completed tasks into the archive viewport.")
        // The archive is a SidePanel atom along the window's trailing edge; its close button slides it away.
        let archivePanel = element("done-archive-panel")
        let boardWindow = app.windows.firstMatch
        XCTAssertTrue(archivePanel.exists, "The archive is presented in its SidePanel.")
        XCTAssertEqual(archivePanel.frame.width, 340, accuracy: 1, "The archive's side panel is 340 points wide.")
        XCTAssertEqual(archivePanel.frame.maxX, boardWindow.frame.maxX, accuracy: 2, "The side panel slides in along the window's trailing edge.")
        XCTAssertTrue(archivePanel.frame.contains(archiveList.frame), "The list sits inside the side panel.")
        attachScreenshot(named: "Board Done archive in its SidePanel")
        element("close-done-archive-button").click()
        XCTAssertTrue(waitUntil({ !archivePanel.exists && !archiveList.exists }, timeout: 5), "The close button slides the archive away.")
        archiveButton.click()
        XCTAssertTrue(archivePanel.waitToExist(timeout: 5), "The archive button opens the side panel again.")
        XCTAssertTrue(element("done-archive-task-\(titleMatchID)").waitToExist(timeout: 10), "The reopened archive lists the newest completed task.")
        let archiveSearch = element("done-archive-search")
        archiveSearch.click()
        archiveSearch.typeText("no-such-archive-task")
        XCTAssertTrue(element("done-archive-empty-state").waitToExist(timeout: 10), "A search with no matches should show an empty state.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("FiXtUrE-SeCrEt")
        let titleMatchResult = element("done-archive-task-\(titleMatchID)")
        XCTAssertTrue(titleMatchResult.waitToExist(timeout: 10), "A title match should appear in the archive search results.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("answers RECEIVED: blue")
        XCTAssertTrue(waitUntil({ archiveResult.exists && !titleMatchResult.exists }, timeout: 10), "Searching the assistant's stored reply should show its conversation match and filter out unrelated title matches.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("FIRST time CONTRIBUTORS tomorrow")
        XCTAssertTrue(waitUntil({ archiveResult.exists && !titleMatchResult.exists }, timeout: 10), "Searching the user's stored prompt should show its conversation match and filter out unrelated title matches.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText(currentTitle)
        XCTAssertTrue(archiveResult.waitToExist(timeout: 10))
        XCTAssertFalse(titleMatchResult.exists)
        archiveResult.click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        let archivedAnswer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Answers received: Blue / fixture-secret.")
        ).firstMatch
        XCTAssertTrue(archivedAnswer.waitToExist(timeout: 10))
        XCTAssertTrue(element("message-composer").exists, "Archived conversations keep the composer for follow-up questions.")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done", "Leaving the archived conversation must not alter the archived task.")
        attachScreenshot(named: "Completed task opens from the searchable archive with its composer")
    }
    // case-contract: test_review_pr_conflicts_probe_shows_red_link | Separate Review task cards probe their linked pull requests concurrently on app focus, with refreshes limited to one per 20 seconds, with focus events during cooldown coalesced into one trailing refresh. `task pr status` reports a conflicting pull request with hasConflicts and red health beside a mergeable green one, and a mergeable pull request whose remote head is not pushed locally with its differing remote and local heads and no conflict. The board colours the conflicting pull request's number red and the mergeable one's green, with no separate conflict action on either card (Green mode fixes conflicts), and gives each PR link a hit target of at least 30×30 points. `task pr verify` is no longer a command: it fails as invalid_argument pointing at help.
    func test_review_pr_conflicts_probe_shows_red_link() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [123, 456]).merging(Self.prCheckCooldownEnvironment) { $1 }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Review PR conflict UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Review PR conflict UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review PR conflict UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(taskID)").exists }, timeout: 10))
        let secondCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Second Review PR conflict UI", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path,
            "--merge-target", "\(fixture.secondary.path)=main",
        ])["result"] as? [String: Any])
        let secondTaskID = try XCTUnwrap(secondCreated["id"] as? String)
        openTask(named: "Second Review PR conflict UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Second Review PR conflict UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(secondTaskID)").exists }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/playhouse-test/fixture/pull/123")
        try seedTaskPullRequest(taskID: secondTaskID, number: 456, url: "https://github.com/playhouse-test/fixture/pull/456")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        let link = element("task-pr-link-\(taskID)-123")
        let conflictActions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-resolve-pr-conflicts-"))
        XCTAssertTrue(link.waitToExist(timeout: 10))
        let secondLink = element("task-pr-link-\(secondTaskID)-456")
        XCTAssertTrue(secondLink.waitToExist(timeout: 10))
        XCTAssertGreaterThanOrEqual(secondLink.frame.width, 30, "The second task's PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(secondLink.frame.height, 30, "The second task's PR link should have a comfortable vertical hit target.")
        let startedDirectory = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STARTED_DIRECTORY"]))
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("123").path) }, timeout: 10))
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("456").path) }, timeout: 10), "Both Review task probes should overlap on focus.")
        XCTAssertTrue(waitUntil({ (link.value as? String) == "green" }, timeout: 10), "A mergeable PR's number shows green.")
        let ghCallsURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CALL_LOG"]))
        func ghCallCount() -> Int {
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8))?.split(whereSeparator: \.isNewline).count) ?? 0
        }
        // The cooldown is timed from a probe the app starts once it is idle. The launch's probes
        // start while the app is still starting up, so their markers can trail the throttle's
        // own start by more than a later probe's does, which made the cooldown look short.
        var settledCalls = ghCallCount()
        var callsSettled = false
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: Self.prCheckCooldown + 0.1)
            let calls = ghCallCount()
            callsSettled = calls == settledCalls
            guard !callsSettled else { break }
            settledCalls = calls
        }
        XCTAssertTrue(callsSettled, "The launch's GitHub probes should stop within the cooldown before it is timed; calls=\(settledCalls).")
        for number in [123, 456] { try? FileManager.default.removeItem(at: startedDirectory.appendingPathComponent("\(number)")) }
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            [123, 456].allSatisfy { FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("\($0)").path) }
                && ghCallCount() == settledCalls + 2
        }, timeout: 10), "Returning to the app after the cooldown probes both PRs at once.")
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        try "123=conflicting\n".write(to: stateURL, atomically: true, encoding: .utf8)
        // The fixture touches started/<number> as each probe starts, so the marker's date is
        // when the last probe began. The trailing probe that the focus events schedule may
        // start only once the cooldown since then has passed.
        let probeMarkerURL = startedDirectory.appendingPathComponent("123")
        let lastProbeStart = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: probeMarkerURL.path)[.modificationDate] as? Date)
        for number in [123, 456] { try? FileManager.default.removeItem(at: startedDirectory.appendingPathComponent("\(number)")) }
        let callsBeforeCooldownFocus = ghCallCount()
        for _ in 0..<4 {
            activateOtherAppThenReturn()
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: probeMarkerURL.path) }, timeout: 25), "Cooldown focus events should schedule a trailing GitHub probe.")
        let trailingProbeStart = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: probeMarkerURL.path)[.modificationDate] as? Date)
        XCTAssertGreaterThanOrEqual(trailingProbeStart.timeIntervalSince(lastProbeStart), Self.prCheckCooldown - 0.25, "Cooldown focus events should not start an immediate GitHub probe.")
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) == callsBeforeCooldownFocus + 2
        }, timeout: 25), "Cooldown focus events should coalesce into one trailing probe after 20 seconds.")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual((try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count, callsBeforeCooldownFocus + 2, "Four focus changes should produce exactly one probe per linked PR.")
        XCTAssertTrue(waitUntil({ (link.value as? String) == "red" }, timeout: 10), "Focus should discover the conflicting PR and colour its number red.")
        XCTAssertEqual(secondLink.value as? String, "green", "The mergeable PR stays green.")
        XCTAssertEqual(conflictActions.count, 0, "The card offers no separate conflict action; Green mode fixes conflicts.")
        XCTAssertGreaterThanOrEqual(link.frame.width, 30, "A PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(link.frame.height, 30, "A PR link should have a comfortable vertical hit target.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("456").path), "Focus refresh should probe separate Review cards concurrently.")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "A conflicting PR's number shows red with no conflict action (card)")
        attachScreenshot(named: "Review cards with a conflicting red PR and a mergeable green PR")

        // A remote head not pushed locally is reported, and is not a conflict.
        let states = try XCTUnwrap(try runCLI(["task", "pr", "status", taskID], extraEnvironment: ghEnvironment)["result"] as? [[String: Any]])
        XCTAssertEqual(states.first?["hasConflicts"] as? Bool, true)
        XCTAssertEqual(states.first?["health"] as? String, "red")
        try "123=unmerged\n456=head-mismatch\n".write(to: stateURL, atomically: true, encoding: .utf8)
        let mismatch = try XCTUnwrap((try runCLI(["task", "pr", "status", secondTaskID], extraEnvironment: ghEnvironment)["result"] as? [[String: Any]])?.first)
        XCTAssertNotEqual(mismatch["headRefOid"] as? String, mismatch["localHeadOid"] as? String, "A remote head not pushed locally is reported as such.")
        XCTAssertEqual(mismatch["hasConflicts"] as? Bool, false, "An unpushed head is not a conflict.")
        XCTAssertEqual(conflictActions.count, 0)
        assertCLIError(try runCLI(["task", "pr", "verify", taskID], expectedStatus: 2), code: "invalid_argument")
    }
    // case-contract: test_review_sync_pushes_unpushed_changes_on_completion | A completed turn outcome on a task with a PR-linked repository and a configured remote commits local work, merges new remote pull request commits, and pushes the branch before the task reaches Review, so the reviewed worktree holds no local-only changes. A linked repository without a publishing remote is left untouched and still reaches Review. When the sync cannot complete, the task moves to Blocked with the sync failure message instead of resting in Review, and a later successful sync pushes the stranded commits and returns the task to Review. While a provider turn holds the task's worktree, the sync command skips it untouched and reports turn-active. A worktree switched off its task branch fails the sync with a message naming both branches and blocks the task, leaving that other branch and the remote untouched; once switched back, a remote commit whose changes the branch already holds is concluded as a merge commit and pushed, the task returns to Review, and the next sync is up-to-date instead of failing on an unfinished merge. A merge Git refuses outright, such as one with unrelated history, blocks the task with Git's own error after the generic merge failure message, and restoring the remote branch heals it back to Review. A clean merge an earlier sync left unfinished on the task branch is concluded as a merge commit and pushed. A task branch deleted on a reachable remote is reported as no-remote-branch and leaves the task in Review.
    func test_review_sync_pushes_unpushed_changes_on_completion() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [123]).merging(Self.prCheckCooldownEnvironment) { $1 }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Review sync push UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Review sync push UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review sync push UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(taskID)").exists }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/playhouse-test/fixture/pull/123")

        let record = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        let branch = try XCTUnwrap(record["branch"] as? String)
        let remote = runDirectory.appendingPathComponent("review-sync-push-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should use a fresh owned bare remote.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGitOutput(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        try runGit(worktree, "push", "--set-upstream", "origin", branch)

        // A reviewer commit on the remote PR branch the local branch has not seen.
        let clone = runDirectory.appendingPathComponent("review-sync-push-clone", isDirectory: true)
        _ = try runGitOutput(runDirectory, "clone", "--branch", branch, remote.path, clone.path)
        try "Remote reviewer commit.\n".write(to: clone.appendingPathComponent("remote-side.txt"), atomically: true, encoding: .utf8)
        try runGit(clone, "add", "remote-side.txt")
        try runGit(clone, "commit", "-m", "Remote PR commit")
        try runGit(clone, "push", "origin", branch)
        let reviewerHead = try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)")

        // Local uncommitted work the completed turn leaves behind.
        try "Local turn output.\n".write(to: worktree.appendingPathComponent("local-side.txt"), atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        openTask(named: "Review sync push UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review sync push UI", whileTurnHeld: {
            // While the provider turn owns the worktree, the sync skips it untouched.
            let skipped = try self.runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)
            let result = try XCTUnwrap(skipped["result"] as? [String: Any])
            XCTAssertEqual(result["skipped"] as? String, "turn-active")
            XCTAssertEqual((result["records"] as? [Any])?.isEmpty, true)
        })
        assertTaskVisible("Review sync push UI", inColumn: "Review")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain", "--untracked-files=all"), "", "A reviewed worktree must hold no local-only changes.")
        let localHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), localHead)
        XCTAssertNotEqual(localHead, reviewerHead, "The sync should push a merge of the reviewer commit and the local work.")
        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent("remote-side.txt"), encoding: .utf8),
            "Remote reviewer commit.\n"
        )
        XCTAssertEqual(try runGitOutput(remote, "show", "refs/heads/\(branch):local-side.txt"), "Local turn output.")

        // A sync the daemon cannot complete blocks the task instead of resting in Review.
        // CLI syncs below pass the gh fixture: the daemon resolves gh from each request's own PATH.
        try runGit(fixture.primary, "remote", "set-url", "origin", runDirectory.appendingPathComponent("missing-remote.git").path)
        try "Unpushable local change.\n".write(to: worktree.appendingPathComponent("local-side.txt"), atomically: true, encoding: .utf8)
        openTask(named: "Review sync push UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review sync push UI", expectedFinalStatus: "Blocked")
        assertTaskVisible("Review sync push UI", inColumn: "Blocked")
        let blockedMessage = try taskRecord(id: taskID)?["statusMessage"] as? String
        XCTAssertTrue((blockedMessage ?? "").contains("couldn't sync this task's changes with its pull request"), blockedMessage ?? "nil")

        // A later successful sync pushes the stranded commit and returns the task to Review.
        try runGit(fixture.primary, "remote", "set-url", "origin", remote.path)
        _ = try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)
        assertTaskVisible("Review sync push UI", inColumn: "Review")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), try runGitOutput(worktree, "rev-parse", "HEAD"))

        // A remote commit whose changes the local branch already holds, as after a squash merge.
        try runGit(clone, "pull", "--ff-only", "origin", branch)
        for repository in [clone, worktree] {
            try "Same change on both sides.\n".write(to: repository.appendingPathComponent("duplicate-side.txt"), atomically: true, encoding: .utf8)
            try runGit(repository, "add", "duplicate-side.txt")
            try runGit(repository, "commit", "-m", "Duplicate change in \(repository.lastPathComponent)")
        }
        try runGit(clone, "push", "origin", branch)
        let duplicateRemoteHead = try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)")

        // A worktree switched off its task branch is never merged into, committed to, or pushed.
        // The board's pull request read records a branch switched by hand, so the app stays
        // closed while the worktree is off its branch: this step is the sync's own check.
        XCTAssertTrue(terminateAppAndWait(app))
        try runGit(worktree, "checkout", "-b", "agent-side-branch")
        let sideHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        let switched = try runCLI(["task", "pr", "sync", taskID], expectedStatus: 1, extraEnvironment: ghEnvironment)
        let switchedMessage = ((switched["error"] as? [String: Any])?["message"] as? String) ?? ""
        XCTAssertTrue(switchedMessage.contains("is on branch 'agent-side-branch', not its pull request branch"), switchedMessage)
        XCTAssertTrue(switchedMessage.contains("'\(branch)'"), switchedMessage)
        let switchedStatusMessage = try taskRecord(id: taskID)?["statusMessage"] as? String
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Blocked")
        XCTAssertTrue((switchedStatusMessage ?? "").contains("agent-side-branch"), switchedStatusMessage ?? "nil")
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD"), sideHead)
        let mergeHead = URL(fileURLWithPath: try runGitOutput(worktree, "rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"), relativeTo: worktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHead.path), "A sync on a switched branch must not start a merge.")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), duplicateRemoteHead)

        // Back on the task branch, the Blocked card still shows why the sync stopped, and the
        // clean merge is committed and pushed rather than left in progress.
        try runGit(worktree, "checkout", branch)
        try runGit(worktree, "branch", "-D", "agent-side-branch")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        assertTaskVisible("Review sync push UI", inColumn: "Blocked")
        let switchedCardMessage = element("task-status-message-\(taskID)")
        XCTAssertTrue(switchedCardMessage.waitToExist(timeout: 10), "The Blocked card shows why the sync stopped.")
        let switchedCardText = accessibleLabelOrValue(of: switchedCardMessage)
        XCTAssertTrue(switchedCardText.contains("agent-side-branch") && switchedCardText.contains("not its pull request branch"), switchedCardText)
        attachScreenshot(named: "review-sync-blocked-on-switched-branch")
        let mergedSync = try XCTUnwrap(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((mergedSync["records"] as? [[String: Any]])?.compactMap { $0["action"] as? String }, ["merged-and-pushed"])
        assertTaskVisible("Review sync push UI", inColumn: "Review")
        XCTAssertTrue(
            waitUntil({ !self.element("task-status-message-\(taskID)").exists || !self.accessibleLabelOrValue(of: self.element("task-status-message-\(taskID)")).contains("agent-side-branch") }, timeout: 10),
            "The healed Review card must not keep the stale branch-switch reason."
        )
        attachScreenshot(named: "review-sync-healed-after-branch-restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHead.path), "A merge whose result matches HEAD must still be concluded.")
        let mergedHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        XCTAssertEqual(try runGitOutput(worktree, "rev-list", "--parents", "-n", "1", mergedHead).split(separator: " ").count, 3)
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), mergedHead)
        let againSync = try XCTUnwrap(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((againSync["records"] as? [[String: Any]])?.compactMap { $0["action"] as? String }, ["up-to-date"])

        // A fatal merge failure reports Git's own error instead of only a generic message.
        let unrelated = try runGitOutput(clone, "commit-tree", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "-m", "Unrelated history")
        try runGit(clone, "push", "--force", "origin", "\(unrelated):refs/heads/\(branch)")
        let fatal = try runCLI(["task", "pr", "sync", taskID], expectedStatus: 1, extraEnvironment: ghEnvironment)
        let fatalMessage = ((fatal["error"] as? [String: Any])?["message"] as? String) ?? ""
        XCTAssertTrue(fatalMessage.contains("Git couldn't merge the remote task branch.") && fatalMessage.contains("unrelated histories"), fatalMessage)
        assertTaskVisible("Review sync push UI", inColumn: "Blocked")
        XCTAssertTrue((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("unrelated histories"))
        try runGit(worktree, "push", "--force", "origin", "\(mergedHead):refs/heads/\(branch)")
        let restoredSync = try XCTUnwrap(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((restoredSync["records"] as? [[String: Any]])?.compactMap { $0["action"] as? String }, ["up-to-date"])
        XCTAssertEqual(restoredSync["status"] as? String, "Review")

        // A clean merge an earlier sync left unfinished on the task branch is concluded and pushed.
        try runGit(clone, "pull", "--ff-only", "origin", branch)
        for repository in [clone, worktree] {
            try "Already merged change.\n".write(to: repository.appendingPathComponent("leftover-side.txt"), atomically: true, encoding: .utf8)
            try runGit(repository, "add", "leftover-side.txt")
            try runGit(repository, "commit", "-m", "Leftover change in \(repository.lastPathComponent)")
        }
        try runGit(clone, "push", "origin", branch)
        try runGit(worktree, "fetch", "--quiet", "origin", branch)
        try runGit(worktree, "merge", "--no-commit", "--no-ff", "FETCH_HEAD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergeHead.path), "The fixture should leave a clean merge unfinished.")
        let leftoverSync = try XCTUnwrap(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((leftoverSync["records"] as? [[String: Any]])?.compactMap { $0["action"] as? String }, ["pushed"])
        XCTAssertEqual(leftoverSync["status"] as? String, "Review")
        assertTaskVisible("Review sync push UI", inColumn: "Review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeHead.path), "The sync should conclude a merge an earlier sync left unfinished.")
        let leftoverHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        XCTAssertEqual(try runGitOutput(worktree, "rev-list", "--parents", "-n", "1", leftoverHead).split(separator: " ").count, 3)
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), leftoverHead)

        // A branch deleted on a reachable remote is reported as missing, not as a fetch failure.
        try runGit(remote, "update-ref", "-d", "refs/heads/\(branch)")
        let deletedSync = try XCTUnwrap(try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((deletedSync["records"] as? [[String: Any]])?.compactMap { $0["action"] as? String }, ["no-remote-branch"])
        XCTAssertEqual(deletedSync["status"] as? String, "Review")
        assertTaskVisible("Review sync push UI", inColumn: "Review")
    }
    // case-contract: test_review_sync_resolves_conflicts_with_provider_or_blocks | When the remote pull request branch conflicts with local task commits, the review sync merges the remote branch and instructs the task's provider to resolve every conflict; if conflicts remain after the provider turn, the sync fails, the task moves to Blocked with the sync failure message, the merge stays in progress for manual resolution, and the remote branch is unchanged. A rerun with the conflicts staged commits the resolution, pushes the merged branch, and returns the task to Review. The board triggers the same sync automatically when a mergeable pull request's remote head diverges from the local head. With the Merge conflict resolution prompt changed in Settings, that provider turn says the merge stopped on conflicts, carries the changed guidance instead of the default, and ends with Playhouse's rule to stage the resolved files without committing or pushing.
    func test_review_sync_resolves_conflicts_with_provider_or_blocks() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        var ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [123]).merging(Self.prCheckCooldownEnvironment) { $1 }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Review sync conflict UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Review sync conflict UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review sync conflict UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(taskID)").exists }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/playhouse-test/fixture/pull/123")

        let record = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        let branch = try XCTUnwrap(record["branch"] as? String)
        let remote = runDirectory.appendingPathComponent("review-sync-conflict-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should use a fresh owned bare remote.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGitOutput(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        try runGit(worktree, "push", "--set-upstream", "origin", branch)
        try runGit(worktree, "push", "origin", "HEAD:refs/heads/pr-123")
        ghEnvironment["PLAYHOUSE_E2E_GH_REMOTE_REPOSITORY"] = remote.path

        // The board pushes a diverged local head automatically, with no conflict action.
        try "Local unpushed change.\n".write(to: worktree.appendingPathComponent("review-sync-local.txt"), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", "review-sync-local.txt")
        try runGit(worktree, "commit", "-m", "Local unpushed commit")
        let localHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        XCTAssertNotEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), localHead)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        XCTAssertTrue(element("task-card-\(taskID)").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({
            (try? self.runGitOutput(remote, "rev-parse", "refs/heads/\(branch)")) == localHead
        }, timeout: 30), "The board should push the diverged local head automatically.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        try runGit(worktree, "push", "origin", "HEAD:refs/heads/pr-123")
        XCTAssertTrue(terminateAppAndWait(app))

        // Conflicting local and remote PR commits: the provider turn resolves nothing,
        // so the sync fails closed and the task blocks instead of resting in Review.
        let conflictPath = "review-sync-conflict.txt"
        try "base version\n".write(to: worktree.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictPath)
        try runGit(worktree, "commit", "-m", "Base for sync conflict")
        try runGit(worktree, "push", "origin", branch)
        try runGit(worktree, "push", "origin", "HEAD:refs/heads/pr-123")
        let clone = runDirectory.appendingPathComponent("review-sync-conflict-clone", isDirectory: true)
        _ = try runGitOutput(runDirectory, "clone", "--branch", branch, remote.path, clone.path)
        try "remote version\n".write(to: clone.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(clone, "add", conflictPath)
        try runGit(clone, "commit", "-m", "Remote conflicting commit")
        try runGit(clone, "push", "origin", branch)
        try runGit(clone, "push", "origin", "HEAD:refs/heads/pr-123")
        let remoteHead = try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)")
        try "local version\n".write(to: worktree.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictPath)
        try runGit(worktree, "commit", "-m", "Local conflicting commit")
        let conflictGuidance = "Keep the remote version of every conflicting line and note what the local commit wanted."
        _ = try runCLI(["settings", "set-prompt", "merge-conflicts", "--text", conflictGuidance])

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked"
        }, timeout: 30), "An unresolvable sync conflict should move the task to Blocked.")
        let codexExecutable = try XCTUnwrap(codexFixtureExecutable)
        let turnPrompts = ((try? String(contentsOf: URL(fileURLWithPath: codexExecutable + ".turn-starts"), encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["text"] as? String }
        let resolutionPrompt = try XCTUnwrap(turnPrompts.last { $0.contains("stopped on conflicts") }, "The sync should ask the provider to resolve the conflicts.")
        XCTAssertTrue(resolutionPrompt.contains(conflictGuidance), "The changed conflict prompt reaches the provider: \(resolutionPrompt)")
        XCTAssertFalse(resolutionPrompt.contains("Preserve the intended changes from both sides"), resolutionPrompt)
        XCTAssertTrue(resolutionPrompt.hasSuffix("Stage the resolved files. Do not commit or push. Report which conflicts you resolved."), resolutionPrompt)
        assertTaskVisible("Review sync conflict UI", inColumn: "Blocked")
        let blockedMessage = try taskRecord(id: taskID)?["statusMessage"] as? String
        XCTAssertTrue((blockedMessage ?? "").contains("couldn't sync this task's changes with its pull request"), blockedMessage ?? "nil")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), remoteHead, "A failed sync must leave the remote branch unchanged.")
        XCTAssertEqual(try runGitOutput(worktree, "diff", "--name-only", "--diff-filter=U"), conflictPath, "The merge should stay in progress for manual resolution.")

        // Staging the resolution lets the shared sync command finish the merge,
        // push the merged branch, and return the task to Review.
        try "resolved local and remote versions\n".write(to: worktree.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictPath)
        // The daemon resolves gh from each request's own PATH, so the CLI sync passes the fixture too.
        _ = try runCLI(["task", "pr", "sync", taskID], extraEnvironment: ghEnvironment)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        assertTaskVisible("Review sync conflict UI", inColumn: "Review")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/\(branch)"), try runGitOutput(worktree, "rev-parse", "HEAD"))
        XCTAssertEqual(try runGitOutput(remote, "show", "refs/heads/\(branch):\(conflictPath)"), "resolved local and remote versions")
    }
    // case-contract: test_task_done_preserves_dirty_worktree | Moving a reviewed task to Done removes its managed worktree and keeps its branch and target commit without committing or merging. When the worktree holds uncommitted changes the move is refused until the user confirms discarding them: declining keeps the task in Review with its files intact, and confirming removes them. A reviewed task stays in Review until it is moved; in the UI the Done drawer rests as a thin sliver beside, not over, the board columns (once a board wider than its window is scrolled to its trailing end) and just left of the board scroller, which keeps the window edge, opens only while a reviewed card is dragged, and returns to rest both after a card is dropped on Done and when a card is dropped back in place without moving the task.
    func test_task_done_preserves_dirty_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Dirty done UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        openTask(named: "Dirty done UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Dirty done UI")
        element("back-to-board-button").click()
        let record = try XCTUnwrap((taskRecord(named: "Dirty done UI")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let path = try XCTUnwrap(record["worktreePath"] as? String)
        let branch = try XCTUnwrap(record["branch"] as? String)
        try "Edited after review\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("playhouse-primary.txt"), atomically: true, encoding: .utf8)
        try "New unsaved work\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("unsaved.txt"), atomically: true, encoding: .utf8)
        let targetBefore = try runGitOutput(fixture.primary, "rev-parse", "main")
        let branchHead = try runGitOutput(URL(fileURLWithPath: path), "rev-parse", "HEAD")
        let card = app.buttons["Dirty done UI"].firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 5))
        assertDoneDrawerResting("before any drag")
        attachScreenshot(named: "Done drawer peeks at the board edge while resting")
        attachRegionScreenshot([element("task-done-drop-target")], named: "Done drawer resting affordance", padding: 12)
        // Dropping a card back in its own column hits no drop target; the drawer must still close.
        let reviewColumn = element("column-review")
        XCTAssertTrue(reviewColumn.waitToExist(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.5,
            thenDragTo: reviewColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
            withVelocity: .default,
            thenHoldForDuration: 0.5
        )
        assertDoneDrawerResting("after a card is dropped back in place")
        XCTAssertEqual(try taskRecord(named: "Dirty done UI")?["status"] as? String, "Review", "Dropping a card in place must not move the task.")
        attachScreenshot(named: "Done drawer closes again after a drop in place")
        let openDrawerCapture = startDelayedScreenCapture(afterSeconds: 2, region: app.windows.firstMatch.frame)
        dragTaskToDone(card)
        attachScreenCapture(openDrawerCapture, named: "Done drawer slides open while a card is dragged")
        // Scoped to the dialog sheet: a bare "Cancel" button also matches a Touch Bar element.
        let discardButton = app.sheets.buttons["Discard Changes and Mark Done"].firstMatch
        let keepButton = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(discardButton.waitToExist(timeout: 10), "A worktree with uncommitted changes must ask before Done discards them.")
        attachScreenshot(named: "Done asks before discarding uncommitted changes")
        // Declining leaves the task and its files exactly as they were.
        keepButton.click()
        XCTAssertTrue(waitUntil({ !discardButton.exists }, timeout: 5), "Cancel should dismiss the confirmation.")
        assertDoneDrawerResting("after declining to discard changes")
        XCTAssertEqual(try taskRecord(named: "Dirty done UI")?["status"] as? String, "Review", "Declining must leave the task in Review.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Declining must keep the task worktree.")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("unsaved.txt"), encoding: .utf8), "New unsaved work\n")
        dragTaskToDone(card)
        XCTAssertTrue(discardButton.waitToExist(timeout: 10))
        discardButton.click()
        XCTAssertTrue(waitUntil({
            do { return try taskRecord(named: "Dirty done UI")?["status"] as? String == "Done" }
            catch { return false }
        }, timeout: 15), "Confirming should persist the Done status.")
        assertDoneDrawerResting("after a card is dropped on Done")
        attachScreenshot(named: "Done drawer closes after a drop on Done")
        try assertTaskArchived("Dirty done UI")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Confirmed Done must remove the task worktree with its uncommitted changes.")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetBefore)
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", branch), branchHead)
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)")
        attachScreenshot(named: "Done removes the worktree and keeps the branch")
    }
    // case-contract: test_task_pr_create_reports_real_gh_failure | The CLI confirms a new repository-backed task persists in Backlog; the UI shows no PR control there, then shows the active-card PR action after the conversation completes with a minimum 30-point hit target, on its own last row below the card title and time row and on the right, with that row absent while the task sits in Backlog. The active-card PR control visibly presents its native help on hover and keeps showing the pointing-hand cursor while its tooltip is up, with the arrow over the window's title bar, while hovering the card itself shows no tooltip and the card remains an openable control; the Done archive PR action remains available with its completed-task label and visibly presents its native help on hover with the pointing-hand cursor, then waits for the task lock before a real GitHub CLI or branch publication failure without saving a PR link or changing Done status. The card's PR button shows its full PR label with its hover capsule around it, not a truncated ellipsis; the button is the built-in pull requests plugin's, which `plugin list` reports as an enabled inline task card plugin.
    func test_task_pr_create_reports_real_gh_failure() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR failure UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        // Manual, the default, kept explicit: this case drives the manual PR path.
        try setPullRequestMode("manual", taskID: taskID)
        XCTAssertEqual(created["status"] as? String, "Backlog")
        XCTAssertTrue(element("task-card-\(taskID)").waitToExist(timeout: 5), "The backlog task card should render before checking its PR controls.")
        XCTAssertFalse(element("task-create-pr-\(taskID)").exists, "Backlog cards must not expose a PR action.")
        let createdRecord = try XCTUnwrap((created["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(createdRecord["mergeTarget"] as? String, "main")
        XCTAssertEqual((try runCLI(["task", "pr", "conflicts", taskID])["result"] as? [String: Any])?["repositories"] as? [String], [])
        openTask(named: "PR failure UI")
        element("conversation-repository-badge-primary").click()
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(mergeTargetValue.waitToExist(timeout: 5))
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "main")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR failure UI")
        element("back-to-board-button").click()
        let activeCreateButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(activeCreateButton.waitToExist(timeout: 5), "An active repository task should expose its PR action on the card.")
        revealOnBoard(activeCreateButton)
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.width, 30, "The PR action should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.height, 30, "The PR action should have a comfortable vertical hit target.")
        // Framed outside its 10-point hover capsule, the 30-point button left "PR" 10 points and drew "…",
        // whose three dots ink about 8 points; "PR" inks nearly its full typographic width.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).hover()
        Thread.sleep(forTimeInterval: 0.3)
        let prLabelWidth = "PR".size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width
        let prInkWidth = try XCTUnwrap(inkWidth(of: activeCreateButton.screenshot().image, pointWidth: activeCreateButton.frame.width), "Could not read the PR button's pixels.")
        XCTAssertGreaterThanOrEqual(prInkWidth, prLabelWidth * 0.8, "The PR button should draw its full PR label, not a truncated ellipsis: \(prInkWidth) pt of ink for \(prLabelWidth) pt of text.")
        attachScreenshot(named: "Active card shows the full PR button")
        // The button is the built-in pull requests plugin's, an inline task card plugin.
        let listedPlugins = try XCTUnwrap((try runCLI(["plugin", "list"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        let pullRequestsPlugin = try XCTUnwrap(listedPlugins.first { $0["id"] as? String == "pull-requests" })
        XCTAssertEqual(pullRequestsPlugin["placement"] as? String, "taskItem")
        XCTAssertEqual(pullRequestsPlugin["presentation"] as? String, "inline")
        XCTAssertEqual(pullRequestsPlugin["builtIn"] as? Bool, true)
        XCTAssertEqual(pullRequestsPlugin["enabled"] as? Bool, true)
        // The control sits on its own last row, below the title and the time row, on the right; Backlog had no such row.
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.minY, element("task-title-\(taskID)").frame.maxY, "The pull-request row should sit below the title.")
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.minY, element("task-token-usage-counter-\(taskID)").frame.maxY, "The pull-request row should sit below the time row.")
        XCTAssertLessThanOrEqual(activeCreateButton.frame.maxY, element("task-card-\(taskID)").frame.maxY + 1, "The pull-request row should be the card's last row.")
        XCTAssertGreaterThan(activeCreateButton.frame.midX, element("task-card-\(taskID)").frame.midX, "The pull-request control should sit on the right.")
        assertHoverEmphasis(for: activeCreateButton)
        XCTAssertEqual(activeCreateButton.label, "PR. Create a pull request for each repository linked to this task")
        assertNativeHelpText(for: activeCreateButton, equals: "Create a pull request for each repository linked to this task")
        attachScreenshot(named: "Active task PR control shows its help text", fullScreen: true)
        // The hand must survive the tooltip: AppKit re-evaluating the cursor once left the arrow.
        assertPointingHandCursor(whileShowingHelp: "Create a pull request for each repository linked to this task", "The active card's PR button")
        dismissNativeHelpText(named: "Create a pull request for each repository linked to this task")
        assertNoNativeHelpText(whileHovering: element("task-title-\(taskID)"), containing: "Open task")
        XCTAssertTrue(element("task-card-\(taskID)").isHittable, "The card should still be a clickable control without its tooltip.")
        XCTAssertEqual(element("task-card-\(taskID)").label, "PR failure UI", "The card keeps its accessibility label.")
        attachScreenshot(named: "Hovering a task card shows no tooltip", fullScreen: true)
        moveTaskToDone(taskID: taskID)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        element("done-archive-button").click()
        let archiveTask = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archiveTask.waitToExist(timeout: 10), "The completed task should be listed in the archive.")
        let createButton = element("done-archive-create-pr-\(taskID)")
        XCTAssertTrue(createButton.waitToExist(timeout: 5))
        assertHoverEmphasis(for: createButton)
        XCTAssertEqual(createButton.label, "PR. Create a pull request for each repository linked to this completed task")
        assertNativeHelpText(for: createButton, equals: "Create a pull request for each repository linked to this completed task")
        attachScreenshot(named: "Completed task PR action shows its help text in the archive")
        attachElementScreenshot(createButton, named: "Completed task PR action help text")
        assertPointingHandCursor(whileShowingHelp: "Create a pull request for each repository linked to this completed task", "The archived task's PR action")
        dismissNativeHelpText(named: "Create a pull request for each repository linked to this completed task")
        let operationLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var operationLockReleased = false
        defer { if !operationLockReleased { try? operationLock.release() } }
        createButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertFalse(app.sheets.firstMatch.exists, "The UI should wait on the task operation lock before starting the real gh lookup.")
        let waitingTask = try XCTUnwrap(taskRecord(id: taskID))
        let waitingRecord = try XCTUnwrap((waitingTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(waitingTask["status"] as? String, "Done")
        XCTAssertNil(waitingRecord["pullRequestNumber"])
        XCTAssertNil(waitingRecord["pullRequestURL"])
        try operationLock.release()
        operationLockReleased = true
        let alertSheet = app.sheets.firstMatch
        XCTAssertTrue(alertSheet.waitToExist(timeout: 20), "The archived task should report gh's inability to create a PR.")
        XCTAssertTrue(waitUntil({
            self.element(containingAccessibilityText: "gh auth login").exists
                || self.element(containingAccessibilityText: "publish the task branch").exists
        }, timeout: 5), app.debugDescription)
        alertSheet.buttons["OK"].click()
        let current = try XCTUnwrap(taskRecord(id: taskID))
        let record = try XCTUnwrap((current["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertNil(record["pullRequestNumber"])
        XCTAssertNil(record["pullRequestURL"])
        XCTAssertEqual(record["mergeTarget"] as? String, "main")
        XCTAssertEqual(current["status"] as? String, "Done")
    }
}

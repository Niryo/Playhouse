import AppKit
import CoreGraphics
import Foundation
import XCTest

final class StationAIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: WorkspaceFixture!
    private var runDirectory: URL!
    private var dataDirectory: URL!
    private var preferencesSuiteName: String!
    private var appBundle: URL!
    private var cliURL: URL!
    private var serviceName: String!
    private var codexFixtureExecutable: String?
    private var selectedRepositoryCount = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        selectedRepositoryCount = 0
        codexFixtureExecutable = nil
        fixture = try WorkspaceFixture.load()
        runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StationAIUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(
            to: runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker),
            atomically: true,
            encoding: .utf8
        )
        dataDirectory = runDirectory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        preferencesSuiteName = "com.stationai.StationAI.E2E.\(UUID().uuidString)"

        appBundle = try Self.findAppBundle()
        cliURL = appBundle.appendingPathComponent("Contents/MacOS/stationai-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliURL.path), "The app-bundled CLI is missing.")
        let serviceInfo = appBundle.appendingPathComponent("Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist")
        let plistData = try Data(contentsOf: serviceInfo)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        serviceName = try XCTUnwrap(plist["CFBundleIdentifier"] as? String)
    }

    override func tearDownWithError() throws {
        if app?.state == .runningForeground || app?.state == .runningBackground {
            app.terminate()
        }
        UserDefaults(suiteName: preferencesSuiteName)?.removePersistentDomain(forName: preferencesSuiteName)

        let markerURL = runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == WorkspaceFixture.ownerContents else {
            XCTFail("Refusing to remove UI test data without its ownership marker: \(runDirectory.path)")
            return
        }
        let testWorktrees = dataDirectory.appendingPathComponent("worktrees", isDirectory: true)
        if FileManager.default.fileExists(atPath: testWorktrees.path) {
            try FileManager.default.removeItem(at: testWorktrees)
            for repository in [fixture.primary, fixture.secondary, fixture.alternate, fixture.changes] {
                try? runGit(repository, "worktree", "prune")
            }
        }
        try FileManager.default.removeItem(at: runDirectory)
    }

    // case-contract: test_service_reports_bridge_version | The real app window opens and the bridge reports StationAI API version 1.
    func test_service_reports_bridge_version() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15), "The StationAI window did not open.")
        let response = try runCLI(["status"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["service"] as? String, "StationAI")
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        attachScreenshot(named: "StationAI board opened with a healthy bridge")
    }

    // case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | Blank titles, missing roots, unavailable roots, and nonexistent merge targets cannot create a task.
    func test_task_creation_rejects_invalid_title_roots_and_missing_folder() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        XCTAssertFalse(element("full-access-notice").exists, "The task creation sheet should not show the full-access notice.")
        let done = element("create-task-button")
        XCTAssertFalse(done.isEnabled, "A task without a repository or context folder must not be creatable.")

        assertCLIError(
            try runCLI(["task", "create", "--title", "   ", "--root", fixture.primary.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["task", "create", "--title", "No roots"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(
                ["task", "create", "--title", "Missing folder", "--root", fixture.missing.path],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI([
                "task", "create", "--title", "Bad merge target", "--repo", fixture.primary.path,
                "--merge-target", "\(fixture.primary.path)=not-a-local-branch"
            ], expectedStatus: 2),
            code: "invalid_argument"
        )
        searchAndChooseRepository("primary")
        openRepositoryTag("repository-merge-target-tag-0", field: "repository-merge-target-0")
        replaceText(element("repository-merge-target-0"), with: "not-a-local-branch")
        element("create-task-button").click()
        let mergeError = element("task-create-error")
        XCTAssertTrue(mergeError.waitForExistence(timeout: 10))
        XCTAssertTrue((mergeError.label + (mergeError.value as? String ?? "")).contains("must name an existing local branch"))
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        XCTAssertEqual(element("task-count").value as? String, "0")
        attachScreenshot(named: "Task creation rejects invalid merge targets")
    }

    // case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | Creating a repository task persists its selected branch settings as pending, shows auto when no branch is chosen, and creates no Git branch or worktree until the first conversation send.
    func test_task_creation_persists_ordered_roots_across_fresh_connections() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        searchAndChooseRepository("secondary")
        searchAndChooseRepository("primary")
        openRepositoryTag("repository-branch-tag-0", field: "repository-branch-0")
        replaceText(element("repository-branch-0"), with: "ordered-roots")
        openRepositoryTag("repository-branch-tag-1", field: "repository-branch-1")
        replaceText(element("repository-branch-1"), with: "ordered-roots")
        openRepositoryTag("repository-branch-from-tag-0", field: "repository-branch-from-0")
        replaceText(element("repository-branch-from-0"), with: "branch-source")
        openRepositoryTag("repository-branch-from-tag-1", field: "repository-branch-from-1")
        replaceText(element("repository-branch-from-1"), with: "branch-source")
        openRepositoryTag("repository-merge-target-tag-1", field: "repository-merge-target-1")
        replaceText(element("repository-merge-target-1"), with: "branch-source")
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add")
        clickCreateTaskAndConfirm("Ordered roots")
        openTask(named: "Ordered roots")
        let task = try XCTUnwrap(taskRecord(named: "Ordered roots"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        let expectedRoots = try XCTUnwrap(task["workspaceRoots"] as? [String])
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["ordered-roots", "ordered-roots"])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["branch-source", "branch-source"])
        XCTAssertEqual(records.map { $0["mergeTarget"] as? String }, ["main", "branch-source"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(expectedRoots, [fixture.secondary.path, fixture.primary.path, fixture.custom.path])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", "ordered-roots").trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertOrderedRoots(expectedRoots)
        XCTAssertEqual(task["status"] as? String, "Backlog")
        let freshRead = try runCLI(["task", "get", try taskID(named: "Ordered roots")])
        let freshTask = try XCTUnwrap(freshRead["result"] as? [String: Any])
        XCTAssertEqual(freshTask["id"] as? String, task["id"] as? String)
        XCTAssertEqual(freshTask["title"] as? String, task["title"] as? String)
        XCTAssertEqual(freshTask["status"] as? String, task["status"] as? String)
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], expectedRoots)
        let freshRecords = try XCTUnwrap(freshTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(freshRecords.map { $0["repositoryPath"] as? String }, records.map { $0["repositoryPath"] as? String })
        XCTAssertEqual(freshRecords.map { $0["branch"] as? String }, records.map { $0["branch"] as? String })
        XCTAssertEqual(freshRecords.map { $0["worktreePath"] as? String }, records.map { $0["worktreePath"] as? String })

        app.buttons["back-to-board-button"].click()
        relaunchApp()
        openTask(named: "Ordered roots")
        assertOrderedRoots(expectedRoots)
        attachScreenshot(named: "Ordered roots persist across UI and XPC reopen")
    }

    // case-contract: test_task_creation_reuses_existing_branch_worktree | A selected existing branch remains pending until task start, then reuses its exact existing worktree path.
    func test_task_creation_reuses_existing_branch_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        searchAndChooseRepository("primary")
        openRepositoryTag("repository-branch-tag-0", field: "repository-branch-0")
        replaceText(element("repository-branch-0"), with: "ui-existing-worktree")
        clickCreateTaskAndConfirm("Reuse existing")
        let task = try XCTUnwrap(taskRecord(named: "Reuse existing"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.first?["isPending"] as? Bool, true)
        XCTAssertEqual(records.first?["worktreePath"] as? String, fixture.primary.path)
        openTask(named: "Reuse existing")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Reuse existing")
        let started = try XCTUnwrap((taskRecord(named: "Reuse existing")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(started["isPending"] as? Bool, false)
        XCTAssertEqual(started["worktreePath"] as? String, fixture.existingWorktree.path)
        XCTAssertEqual(started["createdByStationAI"] as? Bool, false)
        attachScreenshot(named: "Task start reuses the existing branch worktree")
    }

    // case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | Selecting multiple repositories persists pending auto branch records without creating branches or worktrees before the task starts.
    func test_task_creation_creates_worktrees_in_multiple_repositories() throws {
        let branchToken = String(UUID().uuidString.prefix(8)).lowercased()
        let taskTitle = "Multi repository UI \(branchToken)"
        let generatedBranch = "multi-repository-ui-\(branchToken)"
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        searchAndChooseRepository("secondary")
        searchAndChooseRepository("primary")
        XCTAssertTrue(element("repository-branch-tag-0").label.contains("auto"))
        XCTAssertTrue(element("repository-branch-from-tag-0").label.contains("main"))
        clickCreateTaskAndConfirm(taskTitle)
        let task = try XCTUnwrap(taskRecord(named: taskTitle))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["auto", "auto"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["main", "main"])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", generatedBranch).trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertTaskVisible(taskTitle, inColumn: "Backlog")
        attachScreenshot(named: "A task has a separate worktree for each selected repository")
    }

    // case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task persists its context without Git worktrees and reaches Done after a successful turn without attempting a merge.
    func test_task_creation_supports_non_git_folder_only_context() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add")
        clickCreateTaskAndConfirm("Folder-only UI")
        let task = try XCTUnwrap(taskRecord(named: "Folder-only UI"))
        XCTAssertEqual(((task["repositoryWorktrees"] as? [[String: Any]]) ?? []).count, 0)
        XCTAssertEqual(task["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual(task["workspaceRoots"] as? [String], [fixture.custom.path])
        assertTaskVisible("Folder-only UI", inColumn: "Backlog")
        openTask(named: "Folder-only UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Folder-only UI")
        element("back-to-board-button").click()
        mergeTaskToDone("Folder-only UI")
        try assertTaskArchived("Folder-only UI")
        XCTAssertEqual(try taskRecord(named: "Folder-only UI")?["status"] as? String, "Done")
        XCTAssertEqual((try taskRecord(named: "Folder-only UI")?["repositoryWorktrees"] as? [[String: Any]])?.count, 0)
    }

    // case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | A worktree already assigned to another active task is rejected without creating another task.
    func test_task_creation_rejects_worktree_assigned_to_active_task() throws {
        launchApp(defaultParent: fixture.parent.path)
        let branch = "active-shared-\(UUID().uuidString.prefix(8).lowercased())"
        let owner = try runCLI(["task", "create", "--title", "Active owner", "--repo", fixture.primary.path, "--branch", "\(fixture.primary.path)=\(branch)"])["result"] as? [String: Any]
        XCTAssertNotNil(owner)
        openNewTaskSheet()
        searchAndChooseRepository("primary")
        openRepositoryTag("repository-branch-tag-0", field: "repository-branch-0")
        replaceText(element("repository-branch-0"), with: branch)
        element("create-task-button").click()
        let error = element("task-create-error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue((error.label + (error.value as? String ?? "")).contains("already assigned"))
        XCTAssertTrue(element("repository-branch-0").exists, "The user should be able to choose another branch after the conflict.")
        XCTAssertEqual(try tasksFromBoardList().count, 1)
        attachScreenshot(named: "An assigned worktree conflict keeps task creation open with an explanation")
    }

    // case-contract: test_task_done_removes_worktree_and_preserves_branch | After a successful Codex turn puts a task in Review, dropping it on Done squash-merges the task branch, removes the clean managed worktree, retains the source branch and conversation history, reduces the active task count, and exposes the task in the searchable archive with case-insensitive search and a read-only conversation.
    func test_task_done_removes_worktree_and_preserves_branch() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        chooseRepositorySuggestion("primary")
        element("create-task-button").click()
        XCTAssertTrue(element("message-composer").waitForExistence(timeout: 10), "Repository task creation should open the conversation directly.")
        let task = try XCTUnwrap(tasksFromBoardList().first)
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        var path = try XCTUnwrap(record["worktreePath"] as? String)
        var branch = try XCTUnwrap(record["branch"] as? String)
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertEqual(branch, "auto")
        XCTAssertEqual(record["isPending"] as? Bool, true)
        XCTAssertEqual(path, fixture.primary.path)
        let taskPrompt = "Please update the README and add concise setup steps for first time contributors tomorrow."
        let generatedBranch = "please-update-the-readme-and-add-concise-setup"
        XCTAssertEqual(try runGitOutput(fixture.primary, "branch", "--list", generatedBranch).trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(record["mergeTarget"] as? String, "main")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.isEnabled && composer.isHittable }, timeout: 15), "The composer should become available after conversation history loads.")
        composer.click()
        composer.typeText(taskPrompt)
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        let startedRecord = try XCTUnwrap((taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(startedRecord["isPending"] as? Bool, false)
        path = try XCTUnwrap(startedRecord["worktreePath"] as? String)
        branch = try XCTUnwrap(startedRecord["branch"] as? String)
        XCTAssertNotEqual(path, fixture.primary.path)
        XCTAssertEqual(branch, generatedBranch)
        try "Task branch change\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("task-result.txt"), atomically: true, encoding: .utf8)
        try runGit(URL(fileURLWithPath: path), "add", "task-result.txt")
        try runGit(URL(fileURLWithPath: path), "commit", "-m", "Complete task branch")
        element("back-to-board-button").click()
        let titleDeadline = Date().addingTimeInterval(20)
        var currentTitle = "Generating title…"
        while Date() < titleDeadline, currentTitle == "Generating title…" {
            currentTitle = try XCTUnwrap(taskRecord(id: taskID)?["title"] as? String)
            if currentTitle == "Generating title…" { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        }
        XCTAssertNotEqual(currentTitle, "Generating title…", "The title placeholder should eventually resolve.")
        mergeTaskToDone(taskID: taskID)
        XCTAssertTrue(waitUntil({ !element("task-card-\(taskID)").exists }, timeout: 15), "The completed task should disappear from the active board.")
        XCTAssertEqual(element("task-count").value as? String, "0", "The active task count should decrease when a task is archived.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, taskPrompt)
        XCTAssertEqual(try runCLI(["task", "move", taskID, "Done"])["ok"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("task-result.txt"), encoding: .utf8), "Task branch change\n")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-list", "--parents", "-n", "1", "main").split(separator: " ").count, 2)
        XCTAssertEqual(try runGitOutput(fixture.primary, "log", "main", "-1", "--format=%s"), branch.split(separator: "-").map { $0.capitalized }.joined(separator: " "))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")

        let titleMatch = try XCTUnwrap(try runCLI(["task", "create", "--title", "fixture-secret title match", "--root", fixture.custom.path])["result"] as? [String: Any])
        let titleMatchID = try XCTUnwrap(titleMatch["id"] as? String)
        let fixtureExecutable = try XCTUnwrap(codexFixtureExecutable)
        _ = try runCLI(
            ["conversation", "send", titleMatchID, "--message", "Another completed conversation.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureExecutable]
        )
        XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", titleMatchID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")

        element("done-archive-button").click()
        let archiveResult = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archiveResult.waitForExistence(timeout: 10), "The completed task should appear in the archive.")
        let archiveSearch = element("done-archive-search")
        archiveSearch.click()
        archiveSearch.typeText("no-such-archive-task")
        XCTAssertTrue(element("done-archive-empty-state").waitForExistence(timeout: 10), "A search with no matches should show an empty state.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("FiXtUrE-SeCrEt")
        let titleMatchResult = element("done-archive-task-\(titleMatchID)")
        XCTAssertTrue(titleMatchResult.waitForExistence(timeout: 10), "A title match should appear in the archive search results.")
        XCTAssertTrue(archiveResult.waitForExistence(timeout: 10), "Searching saved conversation text should find the completed task.")
        XCTAssertLessThan(titleMatchResult.frame.minY, archiveResult.frame.minY, "Title matches should precede conversation-only matches.")
        archiveResult.click()
        XCTAssertTrue(element("archived-conversation-read-only").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertFalse(element("message-composer").exists, "Archived conversations must not expose the composer.")
        XCTAssertFalse(element("edit-workspace-roots-button").isEnabled, "Archived conversations must not allow workspace edits.")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done", "Leaving the read-only conversation must not alter the archived task.")
        attachScreenshot(named: "Completed task opens from the searchable read-only archive")
    }

    // case-contract: test_task_done_commits_dirty_worktree_changes | Moving a reviewed task to Done stages and commits tracked and untracked worktree changes, squash-merges them into the target as a single-parent commit, and removes the managed worktree.
    func test_task_done_commits_dirty_worktree_changes() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Dirty done UI", "--repo", fixture.primary.path])
        let task = try XCTUnwrap(taskRecord(named: "Dirty done UI"))
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        var path = try XCTUnwrap(record["worktreePath"] as? String)
        openTask(named: "Dirty done UI")
        element("message-composer").click()
        element("message-composer").typeText("Complete this task.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Dirty done UI")?["status"] as? String, "Review")
        let startedRecord = try XCTUnwrap((taskRecord(named: "Dirty done UI")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(startedRecord["isPending"] as? Bool, false)
        path = try XCTUnwrap(startedRecord["worktreePath"] as? String)
        let startedBranch = try XCTUnwrap(startedRecord["branch"] as? String)
        element("back-to-board-button").click()
        try "Edited after review\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("stationai-primary.txt"), atomically: true, encoding: .utf8)
        try "New unsaved work\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("unsaved.txt"), atomically: true, encoding: .utf8)
        mergeTaskToDone("Dirty done UI")
        try assertTaskArchived("Dirty done UI")
        XCTAssertEqual(try taskRecord(named: "Dirty done UI")?["status"] as? String, "Done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("stationai-primary.txt"), encoding: .utf8), "Edited after review\n")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("unsaved.txt"), encoding: .utf8), "New unsaved work\n")
        XCTAssertEqual(try runGitOutput(fixture.primary, "log", startedBranch, "-1", "--format=%s"), "Complete task: Dirty done UI")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-list", "--parents", "-n", "1", "main").split(separator: " ").count, 2)
        attachScreenshot(named: "Done commits, merges, and cleans up tracked and untracked task changes")
    }

    // case-contract: test_task_done_rejects_dirty_merge_target | A dirty local merge target is detected before the merge, leaves the target unchanged, moves the reviewed task to Blocked with the reason, and keeps it out of the Done archive.
    func test_task_done_rejects_dirty_merge_target() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Dirty target", "--repo", fixture.primary.path])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        let targetBefore = try runGitOutput(fixture.primary, "rev-parse", "main")
        openTask(named: "Dirty target")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Dirty target")
        element("back-to-board-button").click()
        let targetFile = fixture.primary.appendingPathComponent("target-unsaved.txt")
        try "Keep target edits.\n".write(to: targetFile, atomically: true, encoding: .utf8)
        mergeTaskToDone("Dirty target")
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "merge target 'main' has uncommitted changes")).firstMatch.exists)
        alert.buttons["OK"].click()
        XCTAssertEqual(try taskRecord(named: "Dirty target")?["status"] as? String, "Blocked")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetBefore)
        XCTAssertTrue(element("task-card-\(taskID)").exists, "A failed completion should remain visible as Blocked.")
        element("done-archive-button").click()
        XCTAssertFalse(element("done-archive-task-\(taskID)").exists, "A failed completion must not appear in the Done archive.")
        element("close-done-archive-button").click()
        try FileManager.default.removeItem(at: targetFile)
    }

    // case-contract: test_task_done_rejects_inaccessible_merge_target | A missing explicit local merge target leaves the branch unmerged and moves the reviewed task to Blocked with the reason.
    func test_task_done_rejects_inaccessible_merge_target() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let created = try runCLI([
            "task", "create", "--title", "Missing target", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=branch-source"
        ])
        XCTAssertEqual(created["ok"] as? Bool, true)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Missing target")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Missing target")
        element("back-to-board-button").click()
        let targetCommit = try runGitOutput(fixture.primary, "rev-parse", "branch-source")
        try runGit(fixture.primary, "branch", "-D", "branch-source")
        mergeTaskToDone("Missing target")
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "isn't an available local branch")).firstMatch.exists)
        alert.buttons["OK"].click()
        XCTAssertEqual(try taskRecord(named: "Missing target")?["status"] as? String, "Blocked")
        try runGit(fixture.primary, "branch", "branch-source", targetCommit)
    }

    // case-contract: test_task_done_retries_partial_multi_repository_merge | A later repository squash-commit failure preserves the earlier completed merge and leaves the failed target unchanged and clean; after retry, StationAI skips the completed merge and finishes the remaining repository.
    func test_task_done_retries_partial_multi_repository_merge() throws {
        let taskTitle = "Partial multi merge \(String(UUID().uuidString.prefix(8)).lowercased())"
        let created = try runCLI([
            "task", "create", "--title", taskTitle, "--repo", fixture.primary.path,
            "--repo", fixture.secondary.path
        ])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let task = try XCTUnwrap(created["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertTrue((try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])).allSatisfy { $0["isPending"] as? Bool == true })
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: taskTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: taskTitle)
        element("back-to-board-button").click()
        let startedTask = try XCTUnwrap(taskRecord(named: taskTitle))
        let records = try XCTUnwrap(startedTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0["isPending"] as? Bool == false })
        for (record, repository) in zip(records, [fixture.primary, fixture.secondary]) {
            let path = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String))
            let filename = "partial-\(repository.lastPathComponent).txt"
            try "Change from \(repository.lastPathComponent).\n".write(
                to: path.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
            try runGit(path, "add", filename)
            try runGit(path, "commit", "-m", "Add \(filename)")
        }
        let hook = fixture.secondary.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let secondaryTargetBefore = try runGitOutput(fixture.secondary, "rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines)

        mergeTaskToDone(taskTitle)
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.buttons["OK"].exists, "The merge failure should be acknowledged before retrying.")
        alert.buttons["OK"].click()
        var partial = try XCTUnwrap(taskRecord(named: taskTitle))
        XCTAssertEqual(partial["status"] as? String, "Blocked")
        var progress = try XCTUnwrap(partial["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(progress.compactMap { $0["mergeCompleted"] as? Bool }, [true, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.primary.appendingPathComponent("partial-primary.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.secondary.appendingPathComponent("partial-secondary.txt").path))
        XCTAssertEqual(try runGitOutput(fixture.secondary, "rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines), secondaryTargetBefore)
        XCTAssertEqual(try runGitOutput(fixture.secondary, "status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines), "")
        attachScreenshot(named: "Partial multi-repository merge records the first successful merge")

        try FileManager.default.removeItem(at: hook)
        openTask(named: taskTitle)
        element("message-composer").click()
        element("message-composer").typeText("Retry the remaining repository merge.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: taskTitle)?["status"] as? String, "Review")
        element("back-to-board-button").click()
        mergeTaskToDone(taskTitle)
        try assertTaskArchived(taskTitle)
        partial = try XCTUnwrap(taskRecord(named: taskTitle))
        XCTAssertEqual(partial["status"] as? String, "Done")
        progress = try XCTUnwrap(partial["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(progress.compactMap { $0["mergeCompleted"] as? Bool }, [true, true])
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("partial-primary.txt"), encoding: .utf8), "Change from primary.\n")
        XCTAssertEqual(try String(contentsOf: fixture.secondary.appendingPathComponent("partial-secondary.txt"), encoding: .utf8), "Change from secondary.\n")
        XCTAssertTrue((try runCLI(["task", "get", taskID]))["ok"] as? Bool == true)
    }

    // case-contract: test_task_merge_conflict_resolution_returns_to_review_and_retries | An active conflict-resolution turn remains In Progress when read, leaves the target branch unchanged, and returns the task to Review; a second Done request merges it.
    func test_task_merge_conflict_resolution_returns_to_review_and_retries() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let created = try runCLI(["task", "create", "--title", "Conflict resolution", "--repo", fixture.primary.path])
        let task = try XCTUnwrap(created["result"] as? [String: Any])
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String))
        let conflictFile = "stationai-primary.txt"
        try "Task branch version.\n".write(to: worktree.appendingPathComponent(conflictFile), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictFile)
        try runGit(worktree, "commit", "-m", "Change task branch version")
        try "Target branch version.\n".write(to: fixture.primary.appendingPathComponent(conflictFile), atomically: true, encoding: .utf8)
        try runGit(fixture.primary, "add", conflictFile)
        try runGit(fixture.primary, "commit", "-m", "Change target branch version")
        let targetBefore = try runGitOutput(fixture.primary, "rev-parse", "main")

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Conflict resolution")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Conflict resolution")
        element("back-to-board-button").click()

        codexFixtureExecutable = "/tmp/stationai-bridge-workspaces/codex-fixture-success-wait"
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        mergeTaskToDone("Conflict resolution")
        let resolutionExecutable = try XCTUnwrap(codexFixtureExecutable)
        let ready = URL(fileURLWithPath: resolutionExecutable + ".resolve-ready")
        let resume = URL(fileURLWithPath: resolutionExecutable + ".resolve-continue")
        let readyDeadline = Date().addingTimeInterval(15)
        while Date() < readyDeadline && !FileManager.default.fileExists(atPath: ready.path) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Moving the conflicting task to Done should start the Codex resolution turn.")
        XCTAssertEqual(try taskRecord(named: "Conflict resolution")?["status"] as? String, "In Progress")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetBefore)
        let conflictText = try String(contentsOf: worktree.appendingPathComponent(conflictFile), encoding: .utf8)
        XCTAssertTrue(conflictText.contains("<<<<<<<"))

        try "Resolved task and target changes.\n".write(to: worktree.appendingPathComponent(conflictFile), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictFile)
        try "Continue the successful resolution turn.\n".write(to: resume, atomically: true, encoding: .utf8)
        let reviewDeadline = Date().addingTimeInterval(10)
        var reviewStatus: String?
        while Date() < reviewDeadline {
            reviewStatus = try taskRecord(named: "Conflict resolution")?["status"] as? String
            if reviewStatus == "Review" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(reviewStatus, "Review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        XCTAssertEqual(try runGitOutput(worktree, "ls-files", "-u").trimmingCharacters(in: .whitespacesAndNewlines), "")
        element("back-to-board-button").click()
        mergeTaskToDone("Conflict resolution")
        try assertTaskArchived("Conflict resolution")
        XCTAssertEqual(try taskRecord(named: "Conflict resolution")?["status"] as? String, "Done")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent(conflictFile), encoding: .utf8), "Resolved task and target changes.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        attachScreenshot(named: "Resolved Git conflict returns to Review before the final merge")
    }

    // case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    func test_task_lifecycle_rollout_clears_records_and_clean_worktrees() throws {
        let clean = try runCLI(["task", "create", "--title", "Rollout clean", "--repo", fixture.primary.path])
        let dirty = try runCLI(["task", "create", "--title", "Rollout dirty", "--repo", fixture.secondary.path])
        let cleanResult = try XCTUnwrap(clean["result"] as? [String: Any])
        let dirtyResult = try XCTUnwrap(dirty["result"] as? [String: Any])
        let cleanRecord = try XCTUnwrap((cleanResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let dirtyRecord = try XCTUnwrap((dirtyResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        let dirtyPath = try XCTUnwrap(dirtyRecord["worktreePath"] as? String)
        let cleanBranch = try XCTUnwrap(cleanRecord["branch"] as? String)
        let dirtyBranch = try XCTUnwrap(dirtyRecord["branch"] as? String)
        try "Keep this worktree.\n".write(to: URL(fileURLWithPath: dirtyPath).appendingPathComponent("keep-dirty.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("task-lifecycle-v2-reset"))

        launchApp(defaultParent: fixture.parent.path)
        XCTAssertEqual(element("task-count").value as? String, "0")
        let resetAlert = app.sheets.firstMatch
        XCTAssertTrue(resetAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(resetAlert.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", dirtyPath)).firstMatch.exists)
        resetAlert.buttons["OK"].click()
        XCTAssertNil(try taskRecord(named: "Rollout clean"))
        XCTAssertNil(try taskRecord(named: "Rollout dirty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: dirtyPath).appendingPathComponent("keep-dirty.txt").path))
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(cleanBranch)")
        try runGit(fixture.secondary, "show-ref", "--verify", "--quiet", "refs/heads/\(dirtyBranch)")
        attachScreenshot(named: "Lifecycle rollout clears tasks and reports a retained dirty worktree")
    }

    // case-contract: test_task_status_transitions_and_rejects_unknown_status | The board keeps stacked Blocked/Backlog and conditional Waiting Response/In Progress sections fully visible, leaves Review as its own column, removes Done from the columns, hides empty status sections, and preserves Codex-owned task status behavior.
    func test_task_status_transitions_and_rejects_unknown_status() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Status transitions", roots: [fixture.primary.path])
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
        assertTaskVisible("Status transitions", inColumn: "Backlog")

        let taskID = try taskID(named: "Status transitions")
        assertCLIError(try runCLI(["task", "move", taskID, "Unknown"], expectedStatus: 2), code: "invalid_argument")
        for status in ["In Progress", "Blocked", "Waiting Response", "Review", "Done", "Backlog"] {
            assertCLIError(try runCLI(["task", "move", taskID, status], expectedStatus: 2), code: "invalid_argument")
        }
        XCTAssertEqual(try taskRecord(named: "Status transitions")?["status"] as? String, "Backlog")
        assertTaskVisible("Status transitions", inColumn: "Backlog")
        attachScreenshot(named: "Waiting Response above In Progress with Review kept separate")
    }

    // case-contract: test_task_rename_persists_and_rejects_blank_title | A rename persists; rejecting a blank rename preserves the last valid title.
    func test_task_rename_persists_and_rejects_blank_title() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Before rename", roots: [fixture.primary.path])
        let card = app.buttons["Before rename"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.rightClick()
        let renameAction = element("rename-task-menu-item")
        XCTAssertTrue(renameAction.waitForExistence(timeout: 5), "The task context menu has no rename action.")
        renameAction.click()

        let titleField = element("rename-task-title-field")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("After rename")
        element("save-task-rename-button").click()
        XCTAssertTrue(app.buttons["After rename"].waitForExistence(timeout: 10))

        let taskID = try taskID(named: "After rename")
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        assertCLIError(
            try runCLI(["task", "rename", taskID, "--title", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        attachScreenshot(named: "Renamed task remains unchanged after rejected blank rename")
    }

    // case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, and rejects an empty list.
    func test_task_roots_set_get_order_deduplication_and_validation() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Edit roots", "--repo", fixture.primary.path])
        openTask(named: "Edit roots")
        element("edit-workspace-roots-button").click()
        XCTAssertTrue(element("save-workspace-roots-button").waitForExistence(timeout: 5))

        element("repository-suggestion-secondary").click()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "secondary")).count, 1)
        XCTAssertFalse(element("repository-suggestion-secondary").exists, "A selected repository must leave the suggestion list.")
        let current = try XCTUnwrap(taskRecord(named: "Edit roots")?["repositoryWorktrees"] as? [[String: Any]])
        _ = try XCTUnwrap(current.first?["worktreePath"] as? String)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "primary ·")).firstMatch.click()
        let secondaryPath = fixture.secondary.lastPathComponent
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondaryPath)).firstMatch.click()
        let saveButton = element("save-workspace-roots-button")
        XCTAssertFalse(saveButton.isEnabled, "The editor must require at least one folder.")
        element("repository-suggestion-secondary").click()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("repository-suggestion-primary").click()
        saveButton.click()
        let taskAfterEdit = try XCTUnwrap(taskRecord(named: "Edit roots"))
        let expectedRoots = try XCTUnwrap(taskAfterEdit["workspaceRoots"] as? [String])
        assertOrderedRoots(expectedRoots)

        let taskID = try taskID(named: "Edit roots")
        let duplicateRoots = try runCLI([
            "task", "roots", "set", taskID,
            "--root", fixture.secondary.path,
            "--root", fixture.secondary.path,
            "--root", fixture.custom.path,
            "--root", fixture.primary.path
        ])
        let rootsAfterCliEdit = try XCTUnwrap((duplicateRoots["result"] as? [String: Any])?["workspaceRoots"] as? [String])
        let result = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(result?["roots"] as? [String], rootsAfterCliEdit)
        assertCLIError(try runCLI(["task", "roots", "set", taskID], expectedStatus: 2), code: "invalid_argument")
        let unchanged = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(unchanged?["roots"] as? [String], rootsAfterCliEdit)
        attachScreenshot(named: "Edited ordered folders in task conversation")
    }

    // case-contract: test_conversation_repository_picker_adds_repository_worktree | Adding a repository persists a pending auto branch; the repository details show labeled read-only branch, merge-from, and merge-to values with pencil controls, and no worktree exists before the first send.
    func test_conversation_repository_picker_adds_repository_worktree() throws {
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI(["task", "create", "--title", "Header repository picker", "--root", fixture.primary.path])["result"] as? [String: Any]
        XCTAssertNotNil(created)
        openTask(named: "Header repository picker")
        element("add-conversation-repository-button").click()
        let search = element("conversation-repository-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("primary")
        let suggestion = element("conversation-repository-suggestion-primary")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-secondary").exists, "Typing a repository name should filter unrelated suggestions.")
        suggestion.click()
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        let title = element("task-view-title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(badge.frame.minX, title.frame.maxX, "Repository badges should appear to the right of the task title.")
        XCTAssertLessThan(abs(badge.frame.midY - title.frame.midY), 8, "Repository badges should share the title row.")
        let record = try XCTUnwrap(taskRecord(named: "Header repository picker"))
        let repositories = try XCTUnwrap(record["repositoryWorktrees"] as? [[String: Any]])
        let primary = try XCTUnwrap(repositories.first { ($0["repositoryPath"] as? String) == fixture.primary.path })
        let worktreePath = try XCTUnwrap(primary["worktreePath"] as? String)
        XCTAssertEqual(worktreePath, fixture.primary.path)
        XCTAssertEqual(primary["isPending"] as? Bool, true)
        XCTAssertEqual(primary["branch"] as? String, "auto")
        XCTAssertEqual(record["workspaceRoots"] as? [String], [fixture.primary.path])
        XCTAssertEqual(record["contextFolders"] as? [String], [])
        let branch = try XCTUnwrap(primary["branch"] as? String)
        let mergeFrom = try XCTUnwrap(primary["branchFrom"] as? String)
        let mergeTo = try XCTUnwrap(primary["mergeTarget"] as? String)
        badge.click()
        XCTAssertEqual(element("conversation-repository-branch-value").label, branch)
        XCTAssertEqual(element("conversation-repository-branch-from-value").label, mergeFrom)
        XCTAssertEqual(element("conversation-repository-merge-target-value").label, mergeTo)
        XCTAssertTrue(app.staticTexts["Branch name"].exists)
        XCTAssertTrue(app.staticTexts["Branch from"].exists)
        XCTAssertTrue(app.staticTexts["Merge to"].exists)
        XCTAssertTrue(element("conversation-repository-branch-from-edit").exists)
        XCTAssertTrue(element("conversation-repository-merge-target-edit").exists)
        XCTAssertTrue(element("conversation-repository-branch-edit").exists)
        element("conversation-repository-branch-edit").click()
        XCTAssertTrue(element("conversation-repository-branch").exists, "The branch value becomes editable only after selecting its pencil control.")
        element("save-conversation-repository-button").click()
        badge.click()
        element("conversation-repository-branch-from-edit").click()
        XCTAssertTrue(element("conversation-repository-branch-from").exists, "The merge-from value becomes editable only after selecting its pencil control.")
        element("save-conversation-repository-button").click()
        badge.click()
        element("conversation-repository-merge-target-edit").click()
        XCTAssertTrue(element("conversation-repository-merge-target").exists, "The merge-to value becomes editable only after selecting its pencil control.")
    }

    // case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check reports the confirmation requirement, and confirmed deletion removes the managed worktree.
    func test_task_delete_removes_task_and_later_lookup_is_not_found() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let pendingTitle = "Pending delete"
        _ = try runCLI(["task", "create", "--title", pendingTitle, "--repo", fixture.secondary.path])
        let pendingTask = try XCTUnwrap(taskRecord(named: pendingTitle))
        let pendingID = try XCTUnwrap(pendingTask["id"] as? String)
        let pendingRecord = try XCTUnwrap((pendingTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(pendingRecord["isPending"] as? Bool, true)
        XCTAssertEqual(pendingRecord["worktreePath"] as? String, fixture.secondary.path)
        let pendingCheck = try runCLI(["task", "delete-check", pendingID])
        XCTAssertEqual((pendingCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, false)
        deleteTaskFromContextMenu(pendingTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitForExistence(timeout: 5))
        element("confirm-delete-task-button").click()
        assertCLIError(try runCLI(["task", "get", pendingID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.secondary.path), "Deleting a pending task must preserve its source repository.")

        let cleanTitle = "Clean delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", cleanTitle, "--repo", fixture.primary.path])
        openTask(named: cleanTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: cleanTitle)
        element("back-to-board-button").click()
        let cleanTask = try XCTUnwrap(taskRecord(named: cleanTitle))
        let cleanID = try XCTUnwrap(cleanTask["id"] as? String)
        let cleanRecord = try XCTUnwrap((cleanTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        XCTAssertEqual(cleanRecord["isPending"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanPath))
        deleteTaskFromContextMenu(cleanTitle)
        let cleanConfirmation = element("confirm-delete-task-button")
        XCTAssertTrue(cleanConfirmation.waitForExistence(timeout: 5))
        cleanConfirmation.click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPath), "Deleting a clean started task must remove its managed worktree.")
        assertCLIError(try runCLI(["task", "get", cleanID], expectedStatus: 3), code: "not_found")

        let dirtyTitle = "Dirty delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", dirtyTitle, "--repo", fixture.primary.path])
        let dirtyID = try taskID(named: dirtyTitle)
        openTask(named: dirtyTitle)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("Prepare a task for deletion.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
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
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Dirty work dropped on trash must require confirmation.")
        cancel.click()
        XCTAssertTrue(app.buttons[dirtyTitle].exists, "Canceling deletion must preserve the task.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath), "Canceling deletion must preserve the worktree.")

        deleteTaskFromContextMenu(dirtyTitle)
        let confirmation = element("confirm-delete-task-button")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyPath), "Confirmed deletion must remove the dirty managed worktree.")
        assertCLIError(try runCLI(["task", "get", dirtyID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Deleted task removed from the board")
    }

    // case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; the ordered last-used repository list persists across fresh CLI/XPC connections and rejects unavailable repositories; Dark and Light appearance choices persist, and Dark renders the workspace canvas as #1E1E1E in the VS Code Dark+ palette.
    func test_default_parent_settings_read_write_clear_and_validation() throws {
        launchApp(defaultParent: nil)
        let initialSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(initialSettings?["defaultParentFolder"] as? String)
        _ = try runCLI(["settings", "set-last-repositories", "--repo", fixture.secondary.path, "--repo", fixture.primary.path])
        let initialRepositories = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(initialRepositories?["lastSelectedRepositories"] as? [String], [fixture.secondary.path, fixture.primary.path])
        assertCLIError(
            try runCLI(["settings", "set-last-repositories", "--repo", fixture.missing.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        let unchangedRepositories = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(unchangedRepositories?["lastSelectedRepositories"] as? [String], [fixture.secondary.path, fixture.primary.path])

        element("new-task-button").click()
        let firstRunPanel = openFolderPanel
        XCTAssertTrue(firstRunPanel.waitForExistence(timeout: 10))
        firstRunPanel.buttons["Cancel"].click()
        XCTAssertEqual(element("task-count").value as? String, "0", "Cancelling the first-run picker must not create a task.")

        element("new-task-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        XCTAssertTrue(element("create-task-button").waitForExistence(timeout: 5))
        element("cancel-task-button").click()

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let appearancePicker = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "appearance-picker").firstMatch
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 5), "Workspace Settings should expose the Dark and Light theme choices.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        appearancePicker.click()
        let lightChoice = preferencesWindow.menuItems["Light"]
        if lightChoice.waitForExistence(timeout: 2) {
            lightChoice.click()
        } else {
            preferencesWindow.buttons["Light"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "light")
        appearancePicker.click()
        let darkChoice = preferencesWindow.menuItems["Dark"]
        if darkChoice.waitForExistence(timeout: 2) {
            darkChoice.click()
        } else {
            preferencesWindow.buttons["Dark"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferencesWindow.exists }, timeout: 5), "Settings should close before checking the workspace canvas.")
        let workspaceCanvas = element("board-columns-scroll-view")
        XCTAssertTrue(workspaceCanvas.waitForExistence(timeout: 5), "The board workspace should be visible.")
        assertPixel(workspaceCanvas.screenshot().image, normalizedX: 0.02, normalizedY: 0.5, rgb: (30, 30, 30))
        app.typeKey(",", modifierFlags: .command)
        let reopenedPreferences = settingsWindow
        XCTAssertTrue(reopenedPreferences.waitForExistence(timeout: 10), "Workspace Settings did not reopen.")
        let chooseParent = reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "choose-default-parent-folder-button").firstMatch
        XCTAssertTrue(chooseParent.waitForExistence(timeout: 10))
        chooseParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.alternateParent, confirmationButton: "Use This Folder")
        assertText("default-parent-folder-path", equals: fixture.alternateParent.path)
        let saved = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(saved?["defaultParentFolder"] as? String, fixture.alternateParent.path)

        assertCLIError(
            try runCLI(["settings", "set-parent", fixture.missing.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertText("default-parent-folder-path", equals: fixture.alternateParent.path)
        reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch.click()
        let cleared = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(cleared?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        attachScreenshot(named: "Workspace settings can be changed and cleared")
    }

    // case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | Suggestions include top-level Git roots and skip nested repositories and symlink targets; blank Return reuses the saved repositories in order, while typing and arrow-key selection overrides that default, which persists after task creation.
    func test_repository_suggestions_skip_nested_repositories_and_symlinks() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-last-repositories", "--repo", fixture.secondary.path, "--repo", fixture.primary.path])
        openNewTaskSheet()
        let repositorySearch = element("workspace-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 5), "The create task sheet should let the user search by repository name.")
        XCTAssertTrue((repositorySearch.placeholderValue ?? "").contains("secondary, primary"), "The picker should show the saved two-repository default.")
        repositorySearch.click()
        repositorySearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("selected-repository-0").waitForExistence(timeout: 5), "Return on an empty search should restore the first saved repository.")
        XCTAssertTrue(element("selected-repository-1").exists, "Return on an empty search should restore every saved repository in order.")
        XCTAssertEqual(element("selected-repository-0").label, "secondary")
        XCTAssertEqual(element("selected-repository-1").label, "primary")
        element("create-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10), "Done should create a task with the restored repositories.")
        let savedRepositories = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(savedRepositories?["lastSelectedRepositories"] as? [String], [fixture.secondary.path, fixture.primary.path])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))

        openNewTaskSheet()
        let overrideSearch = element("workspace-repository-search")
        XCTAssertTrue((overrideSearch.placeholderValue ?? "").contains("secondary, primary"), "Creating a task should preserve the same next-task default.")
        overrideSearch.click()
        replaceText(overrideSearch, with: "alternate")
        XCTAssertTrue(element("repository-suggestion-alternate").waitForExistence(timeout: 10))
        overrideSearch.typeKey(.downArrow, modifierFlags: [])
        overrideSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("selected-repository-0").waitForExistence(timeout: 5))
        XCTAssertEqual(element("selected-repository-0").label, "alternate")
        XCTAssertFalse(element("selected-repository-1").exists, "Typing and choosing a suggestion should replace the saved multi-repository default.")
        element("create-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        let overrideSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(overrideSettings?["lastSelectedRepositories"] as? [String], [fixture.alternate.path])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))

        openNewTaskSheet()
        let persistedOverrideSearch = element("workspace-repository-search")
        XCTAssertTrue((persistedOverrideSearch.placeholderValue ?? "").contains("alternate"), "The arrow-selected repository should become the next task default.")
        persistedOverrideSearch.click()
        persistedOverrideSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("selected-repository-0").waitForExistence(timeout: 5))
        XCTAssertEqual(element("selected-repository-0").label, "alternate")
        XCTAssertFalse(element("selected-repository-1").exists)
        element("cancel-task-button").click()

        openNewTaskSheet()
        let typedReturnSearch = element("workspace-repository-search")
        replaceText(typedReturnSearch, with: "primary")
        XCTAssertTrue(element("repository-suggestion-primary").waitForExistence(timeout: 10))
        typedReturnSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("selected-repository-0").waitForExistence(timeout: 5), "Return after typing should select the matching repository.")
        XCTAssertEqual(element("selected-repository-0").label, "primary")
        XCTAssertFalse(element("selected-repository-1").exists, "Typing and pressing Return should replace the saved alternate repository.")
        element("cancel-task-button").click()

        openNewTaskSheet()
        let emptySearch = element("workspace-repository-search")
        XCTAssertTrue(emptySearch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("repository-suggestion-primary").exists, "Repository suggestions should stay hidden until the user types a query.")
        replaceText(emptySearch, with: "primary")
        XCTAssertTrue(element("repository-suggestion-primary").waitForExistence(timeout: 10))
        XCTAssertFalse(element("repository-suggestion-secondary").exists, "Autocomplete should show only repositories matching the query.")
        XCTAssertFalse(element("repository-suggestion-nested").exists)
        replaceText(emptySearch, with: "linked-outside")
        XCTAssertTrue(app.staticTexts["No matching repositories. Use Browse to add a folder."].waitForExistence(timeout: 5))
        replaceText(emptySearch, with: "group")
        XCTAssertTrue(element("repository-suggestion-secondary").waitForExistence(timeout: 5), "A path-only query should find a repository inside a matching parent folder.")
        XCTAssertFalse(element("repository-suggestion-primary").exists)
        replaceText(emptySearch, with: "changes")

        let result = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        let expectedRepositories = [fixture.primary.path, fixture.secondary.path, fixture.alternate.path, fixture.changes.path].sorted()
        XCTAssertEqual(
            result?["repositories"] as? [String],
            expectedRepositories
        )
        XCTAssertTrue(element("repository-suggestion-changes").exists)
        assertScreenshotIfVisible(named: "Repository suggestions exclude nested and symlinked folders")
    }

    // case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    func test_task_roots_remain_after_default_parent_is_cleared() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Roots survive settings", roots: [fixture.primary.path, fixture.secondary.path])
        openTask(named: "Roots survive settings")
        let savedRoots = try XCTUnwrap(taskRecord(named: "Roots survive settings")?["workspaceRoots"] as? [String])
        assertOrderedRoots(savedRoots)
        app.buttons["back-to-board-button"].click()

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let clearParent = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch
        XCTAssertTrue(clearParent.waitForExistence(timeout: 10))
        clearParent.click()
        let clearedSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(clearedSettings?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        app.typeKey("w", modifierFlags: .command)

        openTask(named: "Roots survive settings")
        assertOrderedRoots(savedRoots)
        let settings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(settings?["defaultParentFolder"] as? String)
        let roots = try runCLI(["task", "roots", "get", try taskID(named: "Roots survive settings")])["result"] as? [String: Any]
        XCTAssertEqual(roots?["roots"] as? [String], [fixture.primary.path, fixture.secondary.path])
        attachScreenshot(named: "Existing task roots survive clearing the default parent")
    }

    // case-contract: test_new_task_has_empty_conversation_history | Creating a task opens its empty conversation with the repository picker search focused and shows Untitled task until a first prompt starts title generation; the task has no stored messages or activity, and backing out immediately deletes it without a confirmation.
    func test_new_task_has_empty_conversation_history() throws {
        launchApp(defaultParent: fixture.parent.path)
        element("new-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Untitled task"].exists, "An empty conversation should keep its untitled title until the first prompt is added.")
        XCTAssertFalse(element("task-title-generating-loader").exists, "Title generation should not start before the first prompt.")
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 10), "A new task should open the repository picker immediately.")
        repositorySearch.typeText("primary")
        XCTAssertEqual(repositorySearch.value as? String, "primary", "Typing immediately after task creation should go into repository search.")
        XCTAssertTrue(app.staticTexts["Start a conversation"].exists)
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertFalse(element("continue-response-button").exists)

        let createdTask = try XCTUnwrap(tasksFromBoardList().first)
        let createdTaskID = try XCTUnwrap(createdTask["id"] as? String)
        let history = try runCLI(["conversation", "history", createdTaskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertNil(history?["diff"])

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertFalse(element("confirm-discard-empty-task-button").exists, "An empty new conversation should return to the board without a discard confirmation.")
        let deleted = try runCLI(["task", "get", createdTaskID], expectedStatus: 3)
        XCTAssertEqual((deleted["error"] as? [String: Any])?["code"] as? String, "not_found")
        attachScreenshot(named: "New conversation shows its empty state")
    }

    // case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while backing out saves an unsent prompt; reopening restores the draft without creating a branch or worktree, and invalid status changes are rejected without mutation.
    func test_task_prompt_draft_persists_after_back() throws {
        codexFixtureExecutable = "/tmp/stationai-bridge-workspaces/codex-fixture-success-wait"
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        chooseRepositorySuggestion("primary")
        element("create-task-button").click()
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Task creation should open its conversation immediately.")
        let initialTask = try XCTUnwrap(tasksFromBoardList().first)
        let selectedRepository = try XCTUnwrap((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["repositoryPath"] as? String)
        XCTAssertEqual(selectedRepository, fixture.primary.path)
        let initialBranch = try XCTUnwrap((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["branch"] as? String)
        XCTAssertEqual(initialBranch, "auto")
        XCTAssertEqual((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["isPending"] as? Bool, true)
        XCTAssertEqual((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String, fixture.primary.path)
        let prompt = "Please update the README and explain the change."
        composer.click()
        composer.typeText(prompt)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        let titleGenerationReady = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-ready")
        let titleGenerationContinue = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-continue")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: titleGenerationReady.path) }, timeout: 10), "The real app-server fixture should confirm that title generation is in flight.")
        let tasks = try tasksFromBoardList()
        let task = try XCTUnwrap(tasks.first)
        let taskID = try XCTUnwrap(task["id"] as? String)
        let response = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(response?["savedPrompt"] as? String, prompt)
        XCTAssertEqual(response?["status"] as? String, "Backlog")
        let invalid = try runCLI(["task", "prompt", taskID, "--text", "Changed", "--status", "Not a status"], expectedStatus: 2)
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let doneTransition = try runCLI(["task", "prompt", taskID, "--text", "Changed", "--status", "Done"], expectedStatus: 2)
        XCTAssertEqual((doneTransition["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let unchanged = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(unchanged?["savedPrompt"] as? String, prompt)
        XCTAssertEqual(unchanged?["status"] as? String, "Backlog")

        _ = try runCLI(["task", "rename", taskID, "--title", "Stable draft title"])
        try Data("continue\n".utf8).write(to: titleGenerationContinue)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: titleGenerationReady.path) }, timeout: 10), "The fixture should finish the delayed title turn.")
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["title"] as? String) ?? nil) == "Stable draft title"
        }, timeout: 10), "A late title response must not overwrite a title that was renamed while generation was pending.")
        openTask(named: "Stable draft title")
        XCTAssertEqual(composer.value as? String, prompt, "Reopening should restore an unsent draft.")
        element("back-to-board-button").click()
        let stableTitle = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(stableTitle?["title"] as? String, "Stable draft title", "Returning with the saved draft should not restart title generation.")
        attachScreenshot(named: "Unsent task prompt is saved after returning to backlog")
    }

    // case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline in the composer without sending; multiline prompts persist as typed text, blank drafts cannot be sent or stored, and a sent saved prompt remains in conversation history through live-turn controls and history reload.
    func test_conversation_composer_rejects_blank_and_supports_live_turn_controls() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Blank message", roots: [fixture.primary.path])
        openTask(named: "Blank message")
        let composer = element("message-composer")
        let sendButton = element("send-message-button")
        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10), "The composer should show the selected model next to its send controls.")
        let modelTaskID = try taskID(named: "Blank message")
        let modelResult = try runCLI(["conversation", "models", modelTaskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        let selectedModelName = String(modelPicker.label.split(separator: ":").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = try XCTUnwrap(availableModels.first(where: { ($0["name"] as? String) == selectedModelName || ($0["id"] as? String) == selectedModelName }))
        XCTAssertTrue(modelPicker.label.localizedCaseInsensitiveContains(selectedModel["name"] as? String ?? selectedModelName))
        XCTAssertFalse(sendButton.isEnabled)
        composer.click()
        composer.typeText("First line")
        composer.typeKey(.return, modifierFlags: .shift)
        composer.typeText("Second line")
        XCTAssertEqual(composer.value as? String, "First line\nSecond line", "Shift+Enter should add a line without submitting the composer.")
        XCTAssertTrue(sendButton.isEnabled)
        XCTAssertEqual(((try runCLI(["conversation", "history", taskID(named: "Blank message")])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0, "Adding a line must not send a conversation message.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("   ")
        XCTAssertFalse(sendButton.isEnabled, "Whitespace-only messages must not be sent.")

        let taskID = try taskID(named: "Blank message")
        assertCLIError(
            try runCLI(["conversation", "send", taskID, "--message", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        if FileManager.default.fileExists(atPath: "/tmp/stationai-codex-live-ui-integration") {
            let livePrompt = "In stationai-primary.txt, append exactly the line `StationAI UI pause marker 6A20F1`. Then run a shell command that executes `sleep 90; printf PAUSE_TEST_FINISHED`. Do not modify any other files. Reply with a short summary after the command finishes."
            let savedPrompt = try runCLI(["task", "prompt", taskID, "--text", livePrompt])["result"] as? [String: Any]
            XCTAssertEqual(savedPrompt?["savedPrompt"] as? String, livePrompt)
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeText(livePrompt)
            XCTAssertTrue(sendButton.isEnabled, "A nonblank draft in a live Codex session should enable Send.")
            sendButton.click()

            let pauseButton = element("pause-response-button")
            XCTAssertTrue(pauseButton.waitForExistence(timeout: 60), "A live turn should replace Send with Pause.")
            XCTAssertTrue(pauseButton.isEnabled, "Pause should be enabled after Codex reports an active turn.")

            element("back-to-board-button").click()
            openTask(named: "Blank message")
            XCTAssertTrue(element("pause-response-button").waitForExistence(timeout: 30), "Reopening the task should retain the active-turn controls.")
            XCTAssertEqual(composer.value as? String, "", "A prompt already sent to Codex must not reappear as a composer draft.")
            let reopenedActivity = element("codex-activity-disclosure")
            let visibleThinking = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Thinking", "Running")
            let thinkingExpectation = XCTNSPredicateExpectation(predicate: visibleThinking, object: reopenedActivity)
            XCTAssertEqual(XCTWaiter.wait(for: [thinkingExpectation], timeout: 30), .completed, "An active turn should remain visibly active after leaving and reopening the task.")

            let activityDisclosure = element("codex-activity-disclosure")
            guard activityDisclosure.waitForExistence(timeout: 60) else {
                attachScreenshot(named: "Live turn did not surface Codex activity")
                let liveHistory = try? runCLI(["conversation", "history", taskID])
                let liveRows = ((liveHistory?["result"] as? [String: Any])?["activities"] as? [[String: Any]] ?? [])
                    .map { "\($0["status"] ?? "unknown"): \($0["title"] ?? "untitled")" }
                let task = try taskRecord(named: "Blank message")
                let roots = task?["workspaceRoots"] as? [String] ?? []
                let markerPath = roots.first.map { URL(fileURLWithPath: $0).appendingPathComponent("stationai-primary.txt") }
                let markerPresent = markerPath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("StationAI UI pause marker 6A20F1") ?? false
                XCTFail("The active tool did not appear in the UI. Persisted activity rows: \(liveRows); fixture edit applied: \(markerPresent).")
                return
            }
            let runningTitle = NSPredicate(format: "label CONTAINS %@", "Running 1 task")
            let runningActivityExpectation = XCTNSPredicateExpectation(predicate: runningTitle, object: activityDisclosure)
            XCTAssertEqual(
                XCTWaiter.wait(for: [runningActivityExpectation], timeout: 60),
                .completed,
                "The collapsed activity title should report the current running-task count."
            )
            attachScreenshot(named: "Running response with collapsed Codex activity")
            let activityRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "codex-activity-row-", "sleep 90; printf PAUSE_TEST_FINISHED"))
                .firstMatch
            XCTAssertFalse(activityRow.exists, "Activity details should stay collapsed until opened.")
            activityDisclosure.click()
            XCTAssertTrue(activityRow.waitForExistence(timeout: 30), "Opening activity details should show the running command row.")
            attachScreenshot(named: "Running chat composer and expanded Codex activity")

            pauseButton.click()
            let continueButton = element("continue-response-button")
            XCTAssertTrue(continueButton.waitForExistence(timeout: 30), "An interrupted response should offer Continue.")
            attachScreenshot(named: "Paused response with Continue control")
            continueButton.click()
            XCTAssertTrue(sendButton.waitForExistence(timeout: 120), "The continued response should return the composer to Send.")
            let pauseEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pauseButton)
            let continueEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: continueButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [pauseEnded, continueEnded], timeout: 30),
                .completed,
                "A completed response should no longer show Pause or Continue."
            )
            let completedAssistantMessage = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value != ''", "assistant-message-"))
                .firstMatch
            XCTAssertTrue(completedAssistantMessage.waitForExistence(timeout: 30), "Continue should finish the response and show its assistant message in the conversation.")
            attachScreenshot(named: "Continued response completed in the conversation")
        }
        attachScreenshot(named: "Blank composer leaves send disabled")
    }

    // case-contract: test_conversation_sends_image_attachments | The conversation composer accepts images from the picker and paste, previews them before sending, sends image-only or text-and-image prompts to Codex using the tagged image URL payload, and displays attached images from reloaded conversation history.
    func test_conversation_sends_image_attachments() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Image conversation", roots: [fixture.primary.path])
        openTask(named: "Image conversation")
        let image = dataDirectory.appendingPathComponent("chat-image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let attach = element("attach-chat-image-button")
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attach.click()
        let picker = app.sheets["open-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Attach should open the system image picker.")
        picker.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5))
        try chooseFile(in: picker, goToSheet: goToSheet, file: image)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "The chosen image should appear in the composer preview.")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("What is shown in this screenshot?")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        let pickedTurnData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))
        let pickedTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: pickedTurnData) as? [String: Any])
        XCTAssertEqual(pickedTurn["userMessage"] as? String, "What is shown in this screenshot?")
        XCTAssertEqual((pickedTurn["images"] as? [String])?.count, 1, "The fixture should receive the picker image alongside the text prompt.")
        let pickedImage = try XCTUnwrap((pickedTurn["images"] as? [String])?.first)
        XCTAssertTrue(pickedImage.hasPrefix("data:image/png;base64,"), "The fixture should receive the image as a data URL.")
        XCTAssertEqual(pickedTurn["imageInputs"] as? [[String: String]], [["type": "image", "url": pickedImage]], "The Codex request should use the tagged image URL payload.")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture").waitForExistence(timeout: 10), "Reloaded history should retain the picker attachment.")
        XCTAssertTrue(app.images["user-message-item_user_fixture"].waitForExistence(timeout: 10), "Conversation history should render the picker image.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        try createTaskFixture(title: "Pasted image conversation", roots: [fixture.primary.path])
        openTask(named: "Pasted image conversation")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([try XCTUnwrap(NSImage(contentsOf: image))])
        let pastedComposer = element("message-composer")
        pastedComposer.click()
        pastedComposer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "Pasting an image should create a composer preview.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture").waitForExistence(timeout: 10), "History reload should leave the pasted attachment in the conversation.")
        XCTAssertTrue(app.images["user-message-item_user_fixture"].waitForExistence(timeout: 10), "Conversation history should render the pasted image itself.")
        let pastedTurnData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))
        let pastedTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: pastedTurnData) as? [String: Any])
        XCTAssertTrue(pastedTurn["userMessage"] is NSNull, "The fixture should receive no text for the pasted image-only turn.")
        XCTAssertEqual((pastedTurn["images"] as? [String])?.count, 1, "The fixture should receive the pasted image.")
        let pastedImage = try XCTUnwrap((pastedTurn["images"] as? [String])?.first)
        XCTAssertTrue(pastedImage.hasPrefix("data:image/png;base64,"), "The pasted image should reach Codex as a data URL.")
        XCTAssertEqual(pastedTurn["imageInputs"] as? [[String: String]], [["type": "image", "url": pastedImage]], "Image-only requests should use the tagged image URL payload.")
        attachScreenshot(named: "Chat sends picker text-and-image and pasted image-only messages")
    }

    // case-contract: test_conversation_rejects_invalid_image_attachments | Malformed image data is rejected with a visible composer error and an invalid_argument bridge response, without creating conversation history or advancing task status.
    func test_conversation_rejects_invalid_image_attachments() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Invalid image conversation", roots: [fixture.primary.path])
        openTask(named: "Invalid image conversation")
        let invalid = dataDirectory.appendingPathComponent("invalid-chat-image.png")
        try Data("not an image".utf8).write(to: invalid)
        element("attach-chat-image-button").click()
        let picker = app.sheets["open-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5))
        try chooseFile(in: picker, goToSheet: goToSheet, file: invalid)
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Pasting malformed image bytes should show a visible validation error.")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("valid images"))
        XCTAssertTrue(element("send-message-button").isEnabled == false, "An invalid image must not enable send.")

        let taskID = try taskID(named: "Invalid image conversation")
        let bridgeResult = try runCLI(["conversation", "send", taskID, "--image", invalid.path], expectedStatus: 2)
        XCTAssertEqual((bridgeResult["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Backlog")
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
    }

    // case-contract: test_conversation_shows_subagent_delegation | When Codex delegates a task to a subagent, the conversation activity shows the delegated task and its completion status during the turn and after history reload.
    func test_conversation_shows_subagent_delegation() throws {
        let fixtureRoot = URL(fileURLWithPath: "/tmp/stationai-bridge-workspaces", isDirectory: true)
        let fixtureOwnerMarker = fixtureRoot.appendingPathComponent(".stationai-bridge-fixture")
        XCTAssertEqual(
            try String(contentsOf: fixtureOwnerMarker, encoding: .utf8),
            "StationAI bridge tests own this deterministic fixture (v1).\n",
            "Refusing to place the Codex fixture in a directory StationAI does not own."
        )
        let fixtureCopy = fixtureRoot.appendingPathComponent("codex-fixture-subagent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the subagent fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        _ = try runCLI(["task", "create", "--title", "Subagent delegation", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Subagent delegation")
        let sent = try runCLI(
            ["conversation", "send", taskID, "--message", "Delegate this task."],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
        )
        let sentResult = try XCTUnwrap(sent["result"] as? [String: Any])
        let sentActivities = try XCTUnwrap(sentResult["activities"] as? [[String: Any]])
        XCTAssertEqual(sentActivities.first?["title"] as? String, "Task delegated to subagent")
        let previousApp = XCUIApplication()
        if previousApp.state != .notRunning {
            previousApp.terminate()
        }
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Subagent delegation")

        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "StationAI must be foreground before inspecting the conversation.")

        let activityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(activityDisclosure.waitForExistence(timeout: 20), "A delegated task should appear in conversation activity.")
        activityDisclosure.click()
        let activityRow = element("codex-activity-row-item_stationai_subagent")
        XCTAssertTrue(activityRow.waitForExistence(timeout: 10))
        XCTAssertTrue(activityRow.label.contains("Task delegated to subagent"))
        XCTAssertTrue(activityRow.label.contains("Completed"))
        let activityDetail = element("codex-activity-detail-item_stationai_subagent")
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 5))
        let detailDescription = "\(activityDetail.label) \(activityDetail.value as? String ?? "")"
        XCTAssertTrue(detailDescription.contains("Inspect the project structure and report relevant files."))
        attachScreenshot(named: "Conversation shows a completed subagent delegation")
    }

    // case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer shows a Codex-reported model, while unsupported modes and malformed model IDs are rejected before creating history.
    func test_conversation_mode_rejects_unknown_mode_without_starting_a_turn() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Conversation modes", roots: [fixture.primary.path])
        openTask(named: "Conversation modes")

        let taskID = try taskID(named: "Conversation modes")
        let modelResult = try runCLI(["conversation", "models", taskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        XCTAssertFalse(availableModels.isEmpty)
        let modelMenu = element("model-picker-menu")
        XCTAssertTrue(modelMenu.waitForExistence(timeout: 10))
        let selectedModelName = String(modelMenu.label.split(separator: ":").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = try XCTUnwrap(availableModels.first(where: { ($0["name"] as? String) == selectedModelName || ($0["id"] as? String) == selectedModelName }))
        let selectedModelID = try XCTUnwrap(selectedModel["id"] as? String)
        XCTAssertTrue(modelMenu.label.localizedCaseInsensitiveContains(selectedModelName))
        if let alternateModel = availableModels.first(where: { $0["id"] as? String != selectedModelID }) {
            let alternateID = try XCTUnwrap(alternateModel["id"] as? String)
            modelMenu.click()
            let optionID = "model-option-\(alternateID)"
            let modelOption = app.menuItems.matching(identifier: optionID).firstMatch
            XCTAssertTrue(modelOption.waitForExistence(timeout: 5), "The model picker should list each model returned by Codex.")
            modelOption.click()
            let updatedModelPicker = element("model-picker-menu")
            XCTAssertTrue(updatedModelPicker.waitForExistence(timeout: 5))
            XCTAssertTrue(updatedModelPicker.label.localizedCaseInsensitiveContains(alternateModel["name"] as? String ?? alternateID), "Choosing a model should update the composer selection.")
        }

        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 10))
        modeMenu.click()
        let planMode = app.menuItems["Plan mode"]
        XCTAssertTrue(planMode.waitForExistence(timeout: 5))
        planMode.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))

        let composer = element("message-composer")
        composer.click()
        composer.typeText("/plan")
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Typing /plan should switch modes without sending a message.")

        assertCLIError(
            try runCLI(
                ["conversation", "send", taskID, "--message", "Hello", "--mode", "unsupported"],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        attachScreenshot(named: "Plan mode is visible in the conversation composer")
    }

    // case-contract: test_codex_questions_can_be_answered_over_cli_xpc | Structured questions raised in Plan mode move the task into the conditional Waiting Response board section even when Codex marks the request non-blocking; reopening preserves its status, keyed answers resume In Progress, and successful completion moves it to Review.
    func test_codex_questions_can_be_answered_over_cli_xpc() throws {
        let created = try runCLI(["task", "create", "--title", "Codex questions", "--root", fixture.primary.path])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        codexFixtureExecutable = "/tmp/stationai-bridge-workspaces/codex-fixture-plan-slow"
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Codex questions")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
        element("message-composer").click()
        element("message-composer").typeText("Please ask your questions.")
        element("send-message-button").click()

        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertTrue(element("column-heading-waiting-response").waitForExistence(timeout: 5))
        let waitingResponseColumn = element("column-waiting-response")
        let waitingTaskCard = waitingResponseColumn.buttons["task-card-\(taskID.uppercased())"]
        XCTAssertTrue(waitingTaskCard.waitForExistence(timeout: 8), "The created task is not in Waiting Response.")
        let inProgressColumn = element("column-in-progress")
        let boardViewport = element("board-columns-scroll-view")
        XCTAssertTrue(waitingResponseColumn.frame.maxY < inProgressColumn.frame.minY)
        XCTAssertGreaterThanOrEqual(waitingResponseColumn.frame.minY, boardViewport.frame.minY)
        XCTAssertLessThanOrEqual(inProgressColumn.frame.maxY, boardViewport.frame.maxY)
        attachScreenshot(named: "Waiting Response appears above In Progress while a task awaits an answer")
        waitingTaskCard.click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 5), "Reopening the task should restore the pending question.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response", "Reopening a pending Plan-mode question must preserve Waiting Response.")
        XCTAssertFalse(element("submit-ai-answers-button").isEnabled, "Blank answers must not be submitted.")
        app.buttons["Blue"].click()
        let secretAnswer = element("ai-question-answer-token")
        XCTAssertTrue(secretAnswer.exists)
        secretAnswer.click()
        secretAnswer.typeText("fixture-secret")
        attachScreenshot(named: "Codex structured questions with option and private answer fields")
        element("submit-ai-answers-button").click()

        let resumeDeadline = Date().addingTimeInterval(5)
        var resumedStatus: String?
        while Date() < resumeDeadline {
            resumedStatus = try taskRecord(id: taskID)?["status"] as? String
            if resumedStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(resumedStatus, "In Progress", "Submitting the blocking answer should resume the task before the turn completes.")

        let completionDeadline = Date().addingTimeInterval(10)
        var completedStatus: String?
        while Date() < completionDeadline {
            completedStatus = try taskRecord(id: taskID)?["status"] as? String
            if completedStatus == "Review" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Review", "The submitted answer should complete the task into Review.")
        XCTAssertFalse(element("ai-question-form-title").exists)
    }

    // case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section and completes the task into Review.
    func test_codex_empty_question_request_is_rejected() throws {
        let created = try runCLI(["task", "create", "--title", "Empty Codex questions", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let emptyFixture = try makeCodexFixture(emptyQuestions: true).path
        let failedTurn = try runCLI(
            ["conversation", "send", taskID, "--message", "Please ask your questions."],
            expectedStatus: 1,
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": emptyFixture]
        )
        XCTAssertFalse(failedTurn["ok"] as? Bool ?? true)
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Blocked")
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("column-heading-blocked").waitForExistence(timeout: 5))
        XCTAssertTrue(element("blocked-waiting-indicator").exists)
        assertTaskVisible("Empty Codex questions", inColumn: "Blocked")
        let boardViewport = element("board-columns-scroll-view")
        let blockedColumn = element("column-blocked")
        let backlogColumn = element("column-backlog")
        XCTAssertLessThan(blockedColumn.frame.maxY, backlogColumn.frame.minY)
        XCTAssertGreaterThanOrEqual(blockedColumn.frame.minY, boardViewport.frame.minY)
        XCTAssertLessThanOrEqual(backlogColumn.frame.maxY, boardViewport.frame.maxY)
        attachScreenshot(named: "Blocked task appears above Backlog while waiting for user intervention")
        let retryFixture = try makeCodexFixture(emptyQuestions: false).path
        _ = try runCLI(
            ["conversation", "send", taskID, "--message", "Retry this task.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": retryFixture]
        )
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Review")
        XCTAssertTrue(waitForDisappearance(element("column-heading-blocked")), "The blocked section should disappear after the task is unblocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
    }

    // case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions remain visible without moving the task out of In Progress, then successful completion moves it to Review.
    func test_codex_nonblocking_question_keeps_task_in_progress() throws {
        _ = try runCLI(["task", "create", "--title", "Non-blocking question", "--root", fixture.primary.path])
        codexFixtureExecutable = "/tmp/stationai-bridge-workspaces/codex-fixture-nonblocking-slow"
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Non-blocking question")
        element("message-composer").click()
        element("message-composer").typeText("Ask non-blocking questions.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "In Progress")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        let nonblockingDeadline = Date().addingTimeInterval(5)
        var nonblockingStatus: String?
        while Date() < nonblockingDeadline {
            nonblockingStatus = try taskRecord(named: "Non-blocking question")?["status"] as? String
            if nonblockingStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(nonblockingStatus, "In Progress", "A non-blocking answer should leave the task active until the turn completes.")
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "Review")
    }

    // case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; reopening while a turn is still active recovers the stale task to Blocked with a reason. Interrupted outcomes also persist Blocked across connections, and a new prompt can finish in Review.
    func test_codex_interrupted_turn_blocks_with_reason_and_can_retry() throws {
        _ = try runCLI(["task", "create", "--title", "Interrupted turn", "--root", fixture.primary.path])
        codexFixtureExecutable = URL(fileURLWithPath: "/tmp/stationai-bridge-workspaces/codex-fixture-interrupted").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Interrupted turn")
        element("message-composer").click()
        element("message-composer").typeText("Start work that will be interrupted.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()

        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10))
        let blocked = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(blocked["status"] as? String, "Blocked")
        XCTAssertTrue((blocked["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)

        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        openTask(named: "Interrupted turn")
        let reopened = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(reopened["status"] as? String, "Blocked")
        XCTAssertTrue((reopened["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)
        element("message-composer").click()
        element("message-composer").typeText("Retry the interrupted task.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Interrupted turn")?["status"] as? String, "Review")

        _ = try runCLI(["task", "create", "--title", "Reopen active turn", "--root", fixture.primary.path])
        codexFixtureExecutable = "/tmp/stationai-bridge-workspaces/codex-fixture-hold"
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        openTask(named: "Reopen active turn")
        element("message-composer").click()
        element("message-composer").typeText("Leave this turn active while StationAI closes.")
        element("send-message-button").click()
        let activeDeadline = Date().addingTimeInterval(10)
        var activeStatus: String?
        while Date() < activeDeadline {
            activeStatus = try taskRecord(named: "Reopen active turn")?["status"] as? String
            if activeStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(activeStatus, "In Progress")
        attachScreenshot(named: "Task remains In Progress while the Codex turn is active")

        relaunchApp()
        openTask(named: "Reopen active turn")
        let recovered = try XCTUnwrap(taskRecord(named: "Reopen active turn"))
        XCTAssertEqual(recovered["status"] as? String, "Blocked")
        XCTAssertTrue((recovered["statusMessage"] as? String)?.localizedCaseInsensitiveContains("reopened before codex") == true)
        attachScreenshot(named: "Reopening StationAI recovers a stale In Progress task as Blocked")
    }

    // case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view separates staged and working Git changes, and selecting text or JSON files opens a calculated, highlighted side-by-side diff over the conversation.
    func test_task_workspace_changes_group_staged_and_unstaged_diffs() throws {
        _ = try runCLI([
            "task", "create", "--title", "Git changes", "--root", fixture.changes.path
        ])
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Git changes")

        XCTAssertTrue(element("staged-changes-section").waitForExistence(timeout: 10))
        XCTAssertTrue(element("working-changes-section").exists)
        XCTAssertTrue(element("workspace-change-staged-shared.txt").exists)
        XCTAssertTrue(element("workspace-change-working-shared.txt").exists)
        XCTAssertTrue(element("workspace-change-working-untracked.txt").exists)
        XCTAssertTrue(element("workspace-change-working-deleted.txt").exists)
        XCTAssertTrue(element("workspace-change-working-syntax.json").exists)
        XCTAssertTrue(element("workspace-change-staged-staged-deleted.txt").exists)

        let taskID = try taskID(named: "Git changes")
        let inventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((inventory?["staged"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((inventory?["working"] as? [[String: Any]])?.count, 5)
        let stagedDiff = try runCLI([
            "task", "changes", "diff", taskID,
            "--repository", fixture.changes.path,
            "--path", "shared.txt",
            "--group", "staged"
        ])["result"] as? [String: Any]
        XCTAssertEqual(stagedDiff?["original"] as? String, "Shared baseline.\n")
        XCTAssertEqual(stagedDiff?["modified"] as? String, "Shared index version.\n")

        element("workspace-change-staged-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitForExistence(timeout: 10))
        assertText("workspace-diff-title", equals: "shared.txt")
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Staged")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        attachScreenshot(named: "Monaco staged diff overlays the task conversation")

        element("workspace-change-working-shared.txt").click()
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Working tree")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")

        element("workspace-change-working-untracked.txt").click()
        assertText("workspace-diff-title", equals: "untracked.txt")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")

        element("workspace-change-working-syntax.json").click()
        assertText("workspace-diff-title", equals: "syntax.json")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        attachScreenshot(named: "Monaco JSON diff uses the local JSON language worker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("workspace-diff-overlay").waitForExistence(timeout: 2))
        XCTAssertTrue(element("empty-conversation").exists, "Closing the diff should reveal the conversation again.")
        attachScreenshot(named: "Conversation returns after closing the Monaco diff")
    }

    // case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | External file edits and Git commits update the open task's changes sidebar automatically, and fresh CLI connections report the same Git status.
    func test_external_git_edits_and_commit_refresh_workspace_changes() throws {
        let repository = runDirectory.appendingPathComponent("external-git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let trackedFile = repository.appendingPathComponent("tracked.txt")
        try "Baseline.\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "StationAI UI Test")
        try runGit(repository, "config", "user.email", "stationai-ui-test@example.invalid")
        try runGit(repository, "add", "tracked.txt")
        try runGit(repository, "commit", "-m", "Baseline")

        let created = try runCLI(["task", "create", "--title", "External Git", "--root", repository.path])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "External Git")
        XCTAssertTrue(element("workspace-changes-empty").waitForExistence(timeout: 10))

        try "Edited externally.\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("workspace-change-working-tracked.txt").waitForExistence(timeout: 10))
        let working = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((working?["working"] as? [[String: Any]])?.map { $0["path"] as? String }, ["tracked.txt"])

        try runGit(repository, "add", "tracked.txt")
        XCTAssertTrue(element("workspace-change-staged-tracked.txt").waitForExistence(timeout: 10))
        try runGit(repository, "commit", "-m", "External commit")
        XCTAssertTrue(element("workspace-changes-empty").waitForExistence(timeout: 10))
        let clean = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((clean?["staged"] as? [Any])?.count, 0)
        XCTAssertEqual((clean?["working"] as? [Any])?.count, 0)
        attachScreenshot(named: "External Git commit clears the open changes sidebar")
    }

    private func launchApp(defaultParent: String?) {
        app = XCUIApplication()
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        app.launchEnvironment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        app.launchEnvironment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = defaultParent ?? "__unset__"
        if let codexFixtureExecutable {
            app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        }
        app.launch()
        app.activate()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15))
    }

    private func makeCodexFixture(emptyQuestions: Bool, nonblocking: Bool = false) throws -> URL {
        let executable = URL(fileURLWithPath: "/tmp/stationai-bridge-workspaces", isDirectory: true)
            .appendingPathComponent(emptyQuestions ? "codex-fixture-empty" : (nonblocking ? "codex-fixture-nonblocking" : "codex-fixture-ui"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "The prepared Codex fixture is missing or not executable.")
        return executable
    }

    private func relaunchApp() {
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15))
    }

    private func openNewTaskSheet() {
        app.activate()
        element("new-task-button").click()
        XCTAssertTrue(element("create-task-button").waitForExistence(timeout: 10))
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func createTaskFixture(title: String, roots: [String]) throws {
        var arguments = ["task", "create", "--title", title]
        for root in roots { arguments += ["--root", root] }
        let result = try runCLI(arguments)["result"] as? [String: Any]
        XCTAssertEqual(result?["title"] as? String, title)
    }

    private func clickCreateTaskAndConfirm(_ title: String) {
        let createButton = element("create-task-button")
        XCTAssertTrue(createButton.isEnabled, "A selected repository or context folder should enable Create.")
        createButton.click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.isEnabled && composer.isHittable }, timeout: 15), "Creating a repository task should open an active conversation composer.")
        composer.click()
        composer.typeText(title)
        element("save-task-prompt-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10), "Saving the task prompt should return to the board.")
        guard let task = try? tasksFromBoardList().first, let taskID = task["id"] as? String else {
            XCTFail("The created task should remain in Backlog after saving its prompt.")
            return
        }
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["title"] as? String) ?? nil) != "Generating title…"
        }, timeout: 20), "The generated task title should resolve before the test continues.")
        _ = try? runCLI(["task", "rename", taskID, "--title", title])
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 10), "The created task should be visible with its test title.")
    }

    private func searchAndChooseRepository(_ name: String) {
        chooseRepositorySuggestion(name)
    }

    private func chooseRepositorySuggestion(_ name: String) {
        let selectedIndex = selectedRepositoryCount
        let searchField = element("workspace-repository-search")
        if searchField.exists {
            replaceText(searchField, with: name)
        }
        let suggestion = app.buttons["repository-suggestion-\(name)"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No repository suggestion for \(name).")
        XCTAssertTrue(suggestion.isHittable, "Repository suggestion \(name) should be reachable in the scrolling picker.")
        suggestion.click()
        XCTAssertTrue(element("selected-repository-\(selectedIndex)").waitForExistence(timeout: 5))
        selectedRepositoryCount += 1
    }

    private func openRepositoryTag(_ tagIdentifier: String, field fieldIdentifier: String) {
        let tag = element(tagIdentifier)
        XCTAssertTrue(tag.waitForExistence(timeout: 5), "Missing editable repository tag: \(tagIdentifier)")
        tag.click()
        XCTAssertTrue(element(fieldIdentifier).waitForExistence(timeout: 5), "Clicking \(tagIdentifier) should show \(fieldIdentifier).")
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func openTask(named title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Task card is missing: \(title)")
        card.click()
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
    }

    private func completeCurrentTaskWithFixtureAnswers(taskTitle: String) throws {
        element("message-composer").click()
        element("message-composer").typeText("Complete this task.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: taskTitle)?["status"] as? String, "Review")
    }

    private func assertTaskVisible(_ title: String, inColumn status: String) {
        let column = element("column-\(status.lowercased().replacingOccurrences(of: " ", with: "-"))")
        XCTAssertTrue(column.waitForExistence(timeout: 5), "Missing \(status) column.")
        XCTAssertTrue(column.buttons[title].waitForExistence(timeout: 8), "\(title) is not in \(status).")
    }

    private func assertTaskArchived(_ title: String) throws {
        let taskID = try taskID(named: title)
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitForExistence(timeout: 10), "\(title) should appear in the completed task archive.")
        element("close-done-archive-button").click()
    }

    private func mergeTaskToDone(_ title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        dragTaskToDone(card)
    }

    private func mergeTaskToDone(taskID: String) {
        let card = element("task-card-\(taskID)")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The reviewed task card should remain available by its stable task identifier.")
        dragTaskToDone(card)
    }

    private func dragTaskToDone(_ card: XCUIElement) {
        let cardPoint = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint
        postMouseEvent(.leftMouseDown, at: cardPoint)
        postMouseEvent(.leftMouseDragged, at: CGPoint(x: cardPoint.x + 24, y: cardPoint.y + 8))
        let doneTarget = element("task-done-drop-target")
        XCTAssertTrue(doneTarget.waitForExistence(timeout: 5), "The Done drop target should appear during a task drag.")
        let targetPoint = doneTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint
        postMouseEvent(.leftMouseDragged, at: targetPoint)
        postMouseEvent(.leftMouseUp, at: targetPoint)
        XCTAssertTrue(waitUntil({ !doneTarget.exists }, timeout: 5), "The Done drop target should disappear after completion starts.")
    }

    private func assertPixel(_ image: NSImage, normalizedX: CGFloat, normalizedY: CGFloat, rgb expected: (Int, Int, Int), accuracy: Int = 8, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read workspace screenshot pixels.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * normalizedX)))
        let y = min(cgImage.height - 1, max(0, Int(CGFloat(cgImage.height) * normalizedY)))
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Could not sample workspace background color.", file: file, line: line)
            return
        }
        XCTAssertEqual(Int((color.redComponent * 255).rounded()), expected.0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Int((color.greenComponent * 255).rounded()), expected.1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Int((color.blueComponent * 255).rounded()), expected.2, accuracy: accuracy, file: file, line: line)
    }

    private func postMouseEvent(_ type: NSEvent.EventType, at point: CGPoint) {
        let mouseType: CGEventType
        switch type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseDragged: mouseType = .leftMouseDragged
        case .leftMouseUp: mouseType = .leftMouseUp
        default:
            XCTFail("Unsupported mouse event type: \(type)")
            return
        }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            XCTFail("Could not create mouse event.")
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func deleteTaskFromContextMenu(_ title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.rightClick()
        let deleteAction = element("delete-task-menu-item")
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "The task context menu should offer Delete Task.")
        deleteAction.click()
    }

    private func assertOrderedRoots(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        let summary = element("working-folders-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Working folder summary is missing.", file: file, line: line)
        let text = [summary.label, summary.value as? String ?? "", summary.placeholderValue ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var searchStart = text.startIndex
        for path in paths {
            XCTAssertEqual(
                text.components(separatedBy: path).count - 1,
                1,
                "Folder selection should contain each root once.",
                file: file,
                line: line
            )
            guard let range = text.range(of: path, range: searchStart..<text.endIndex) else {
                XCTFail("Folders are missing or out of order: \(text)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }

    private var openFolderPanel: XCUIElement {
        app.windows.matching(identifier: "open-panel").firstMatch
    }

    private func chooseFolder(in panel: XCUIElement, folder: URL, confirmationButton: String) throws {
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The system folder panel did not open.")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5), "Go to Folder did not open from the system panel.")
        let pathField = goToSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(folder.standardizedFileURL.path)
        pathField.typeKey(.return, modifierFlags: [])
        let location = panel.descendants(matching: .any).matching(identifier: "where popup").firstMatch
        let locationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", folder.lastPathComponent),
            object: location
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [locationExpectation], timeout: 10),
            .completed,
            "Folder panel did not navigate to \(folder.path)."
        )
        let chooseButton = panel.buttons[confirmationButton]
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 10), "Folder panel did not show \(confirmationButton).")
        chooseButton.click()
    }

    private func chooseFile(in panel: XCUIElement, goToSheet: XCUIElement, file: URL) throws {
        let pathField = goToSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(file.deletingLastPathComponent().standardizedFileURL.path)
        pathField.typeKey(.return, modifierFlags: [])
        let target = panel.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@ OR label == %@", file.lastPathComponent, file.lastPathComponent)
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The image picker should show the selected file.")
        target.click()
        let openButton = panel.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        XCTAssertTrue(openButton.isEnabled, "The image file should be selected before opening it.")
        openButton.click()
    }

    private var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
    }

    private func assertText(
        _ identifier: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(identifier)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", expected, expected),
            object: target
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Unexpected text for \(identifier): label=\(target.label), value=\(String(describing: target.value))",
            file: file,
            line: line
        )
    }

    private func tasksFromBoardList() throws -> [[String: Any]] {
        let response = try runCLI(["board", "list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["tasks"] as? [[String: Any]])
    }

    private func taskRecord(named title: String) throws -> [String: Any]? {
        try tasksFromBoardList().first { $0["title"] as? String == title }
    }

    private func taskRecord(id: String) throws -> [String: Any]? {
        let response = try runCLI(["task", "get", id])
        return response["result"] as? [String: Any]
    }

    private func taskID(named title: String) throws -> String {
        let record = try XCTUnwrap(taskRecord(named: title), "No task named \(title) exists in the real store.")
        return try XCTUnwrap(record["id"] as? String)
    }

    private func runCLI(
        _ arguments: [String],
        expectedStatus: Int32 = 0,
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        environment.merge(extraEnvironment) { _, override in override }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, expectedStatus, "CLI \(arguments) exited unexpectedly: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last, "CLI returned no JSON for \(arguments)")
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any],
            "CLI response was not a JSON object."
        )
        XCTAssertEqual(response["version"] as? Int, 1)
        return response
    }

    private func runGit(_ repository: URL, _ arguments: String...) throws {
        _ = try runGitOutput(repository, arguments)
    }

    private func runGitOutput(_ repository: URL, _ arguments: String...) throws -> String {
        try runGitOutput(repository, arguments)
    }

    private func runGitOutput(_ repository: URL, _ arguments: [String]) throws -> String {
        let directGitPaths = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
        ]
        let gitPath = try XCTUnwrap(
            directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) },
            "UI tests need a direct Git executable; /usr/bin/git uses xcrun and cannot run in the test sandbox."
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repository.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "Git failed: \(errorOutput)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertCLIError(
        _ response: [String: Any],
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, code, file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !element.exists
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertScreenshotIfVisible(named name: String) {
        attachScreenshot(named: name)
    }

    private static func findAppBundle() throws -> URL {
        var directory = Bundle(for: StationAIUITests.self).bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("StationAI.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "StationAIUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't locate the app bundle beside the UI test runner."
        ])
    }
}

private struct WorkspaceFixture {
    static let root = URL(fileURLWithPath: "/tmp/stationai-bridge-workspaces", isDirectory: true)
    static let ownerMarker = ".stationai-bridge-fixture"
    static let ownerContents = "StationAI bridge tests own this deterministic fixture (v1).\n"

    let parent: URL
    let primary: URL
    let secondary: URL
    let alternate: URL
    let alternateParent: URL
    let custom: URL
    let changes: URL
    let missing: URL
    let nested: URL
    let linkedOutside: URL
    let existingWorktree: URL

    static func load() throws -> WorkspaceFixture {
        let marker = root.appendingPathComponent(ownerMarker)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8), contents == ownerContents else {
            throw NSError(domain: "StationAIUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The deterministic Git fixtures are missing or not owned by StationAI. Run scripts/test-e2e.sh first."
            ])
        }
        let parent = root.appendingPathComponent("suggested-parent", isDirectory: true)
        let locations: [String: URL] = [
            "parent": parent,
            "primary": parent.appendingPathComponent("primary", isDirectory: true),
            "secondary": parent.appendingPathComponent("group/secondary", isDirectory: true),
            "alternateParent": parent.appendingPathComponent("alternate-parent", isDirectory: true),
            "alternate": parent.appendingPathComponent("alternate-parent/alternate", isDirectory: true),
            "custom": parent.appendingPathComponent("custom-folder", isDirectory: true),
            "changes": parent.appendingPathComponent("changes", isDirectory: true),
            "nested": parent.appendingPathComponent("primary/nested", isDirectory: true),
            "linkedOutside": parent.appendingPathComponent("linked-outside", isDirectory: true)
        ]
        for (name, url) in locations where name != "linkedOutside" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "StationAIUITests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Missing \(name) fixture folder at \(url.path)."
                ])
            }
        }
        return WorkspaceFixture(
            parent: parent,
            primary: locations["primary"]!,
            secondary: locations["secondary"]!,
            alternate: locations["alternate"]!,
            alternateParent: locations["alternateParent"]!,
            custom: locations["custom"]!,
            changes: locations["changes"]!,
            missing: parent.appendingPathComponent("missing", isDirectory: true),
            nested: locations["nested"]!,
            linkedOutside: locations["linkedOutside"]!,
            existingWorktree: root.appendingPathComponent("existing-worktree", isDirectory: true)
        )
    }

}

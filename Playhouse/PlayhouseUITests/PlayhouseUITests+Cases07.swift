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
    // case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; a staged completed outcome is discarded if its turn fails, leaving the task Blocked. The task card removes the report while lifecycle states remain Blocked or In Progress. A blocking structured question appears inline and moves the task to Waiting Response; its answer resumes the active turn in In Progress, and the answered turn finishes in Waiting Response. First-thread instructions distinguish source repository paths from active task worktree paths, allow read-only inspection without attaching a repo, and reserve repository add APIs for changes that need a worktree.
    func test_task_progress_reports_clear_on_failed_turns_and_questions() throws {
        launchApp(defaultParent: fixture.parent.path)
        var heldTurns: [(Process, URL, URL)] = []
        defer {
            for (process, activeMarker, releaseMarker) in heldTurns {
                if process.isRunning {
                    try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                    process.waitUntilExit()
                }
                try? FileManager.default.removeItem(at: activeMarker)
                try? FileManager.default.removeItem(at: releaseMarker)
            }
        }
        for (fixtureName, expectedReason) in [
            ("codex-fixture-progress-hold-release-failed", "failed"),
            ("codex-fixture-progress-hold-release-interrupted", "interrupted"),
        ] {
            let title = "Progress \(expectedReason)"
            try createTaskFixture(title: title, roots: [fixture.primary.path])
            let taskID = try taskID(named: title)
            let executable = WorkspaceFixture.root.appendingPathComponent(fixtureName)
            let turn = try startProgressFixtureTurn(taskID: taskID, executable: executable)
            heldTurns.append((turn.process, turn.activeMarker, turn.releaseMarker))
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: turn.activeMarker.path) }, timeout: 10))
            let staged = try runCLI(["task", "outcome", taskID, "completed"])
            XCTAssertEqual((staged["result"] as? [String: Any])?["outcome"] as? String, "completed")
            XCTAssertEqual((staged["result"] as? [String: Any])?["taskStatus"] as? String, "In Progress")
            let report = element("task-progress-report-\(taskID.uppercased())")
            let label = element("task-progress-label-\(taskID.uppercased())")
            _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing", "--detail", "Waiting for the result"])
            XCTAssertEqual(try taskRecord(id: taskID)?["progressLabel"] as? String, "Testing")
            relaunchApp()
            XCTAssertTrue(element("task-card-\(taskID.uppercased())").waitToExist(timeout: 5), "The active task should appear on the board.")
            XCTAssertEqual(try taskRecord(id: taskID)?["progressLabel"] as? String, "Testing", "Progress should remain persisted after the app relaunches.")
            XCTAssertTrue(waitUntil({ label.exists && (label.value as? String)?.contains("Testing") == true }, timeout: 20), "The active task card should show progress before a failed turn. \(app.debugDescription)")
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")

            try "Release the active turn.\n".write(to: turn.releaseMarker, atomically: true, encoding: .utf8)
            turn.process.waitUntilExit()
            let output = String(data: turn.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let finalLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last)
            let finalResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(finalLine.utf8)) as? [String: Any])
            XCTAssertFalse(finalResponse["ok"] as? Bool ?? true, "The fixture turn should end as \(expectedReason).")
            let stopped = try XCTUnwrap(taskRecord(id: taskID))
            XCTAssertEqual(stopped["status"] as? String, "Blocked")
            XCTAssertNil(stopped["progressLabel"] as? String)
            XCTAssertTrue(waitForDisappearance(report), "A failed or interrupted turn should remove its progress row from the card.")
            assertTaskVisible(title, inColumn: "Blocked")
        }

        let questionFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-progress-user-question")
        codexFixtureExecutable = questionFixture.path
        app.launchEnvironment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = questionFixture.path
        relaunchApp()
        let questionTask = try runCLI([
            "task", "create", "--title", "Progress question", "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path, "--root", fixture.parent.path,
        ])["result"] as? [String: Any]
        let initialRepositories = try XCTUnwrap(questionTask?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(initialRepositories.map { $0["repositoryPath"] as? String }, [fixture.primary.path])
        openTask(named: "Progress question")
        let questionTaskID = try taskID(named: "Progress question")
        let questionHistoryURL = URL(fileURLWithPath: questionFixture.path + ".history")
        let activeMarker = URL(fileURLWithPath: questionFixture.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: questionFixture.path + ".turn-release")
        let outcomeHold = URL(fileURLWithPath: questionFixture.path + ".outcome-hold")
        let outcomeActive = URL(fileURLWithPath: questionFixture.path + ".outcome-active")
        let outcomeRelease = URL(fileURLWithPath: questionFixture.path + ".outcome-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        try? FileManager.default.removeItem(at: outcomeHold)
        try? FileManager.default.removeItem(at: outcomeActive)
        try? FileManager.default.removeItem(at: outcomeRelease)
        defer {
            try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
            try? "Release final turn completion.\n".write(to: outcomeRelease, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
            try? FileManager.default.removeItem(at: outcomeHold)
            try? FileManager.default.removeItem(at: outcomeActive)
            try? FileManager.default.removeItem(at: outcomeRelease)
        }
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The question fixture should hold the turn before asking for input.")
        let waitingReport = try runCLI(["task", "progress", "publish", questionTaskID, "--type", "reviewing", "--detail", "Preparing a question"])
        XCTAssertEqual((waitingReport["result"] as? [String: Any])?["progressLabel"] as? String, "Reviewing")
        try "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10), "Structured questions should appear inline in the conversation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: questionHistoryURL.path) }, timeout: 5))
        let questionHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: questionHistoryURL)) as? [String: Any])
        let threadInstructions = try XCTUnwrap(questionHistory["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(threadInstructions.contains("Active task worktrees for edits"))
        XCTAssertTrue(threadInstructions.contains("workspace repos list"))
        XCTAssertTrue(threadInstructions.contains("task repository add"))
        XCTAssertTrue(threadInstructions.contains("read-only inspection of returned source paths"))
        XCTAssertTrue(threadInstructions.contains("Add a repository to this task only when you intend to create or commit changes in it"))
        XCTAssertTrue(threadInstructions.contains("workspace repos list"))
        XCTAssertTrue(threadInstructions.contains("task repository add"))
        XCTAssertTrue(threadInstructions.contains("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: questionFixture.path + ".assessment.history"), "A question should not spawn a parallel repository-assessment thread.")
        XCTAssertTrue(element("ai-question-form-title").exists)
        XCTAssertEqual(try taskRecord(id: questionTaskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: questionTaskID)?["progressLabel"] as? String, "Progress should clear as soon as Codex requests user input.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5), "The board should reopen after leaving the pending question.")
        let waitingReportLabel = element("task-progress-label-\(questionTaskID.uppercased())")
        XCTAssertTrue(waitForDisappearance(waitingReportLabel), "The active task card should not retain the agent's progress row.")
        openTask(named: "Progress question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 5), "Reopening should restore the pending question inline.")
        selectQuestionOption("Continue")
        try "Hold final turn completion for answer status verification.\n".write(to: outcomeHold, atomically: true, encoding: .utf8)
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: outcomeActive.path) }, timeout: 10), "The fixture should acknowledge the answer and hold final completion.")
        XCTAssertEqual(try taskRecord(id: questionTaskID)?["status"] as? String, "In Progress", "Answering should leave the active turn In Progress until it finishes.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Progress question", inColumn: "In Progress")
        openTask(named: "Progress question")
        try "Release final turn completion.\n".write(to: outcomeRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !element("conversation-user-input-request").exists }, timeout: 5), "Submitting the answer should remove the inline question.")
        XCTAssertTrue(transcriptMessage("Answer received: Continue.").waitToExist(timeout: 10), "The resumed turn should receive the submitted answer.")
        let completionDeadline = Date().addingTimeInterval(10)
        var completedStatus: String?
        while Date() < completionDeadline {
            completedStatus = try taskRecord(id: questionTaskID)?["status"] as? String
            if completedStatus == "Waiting Response" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Waiting Response", "An answered turn without an explicit completion outcome should return to Waiting Response.")
        XCTAssertNil(try taskRecord(id: questionTaskID)?["progressLabel"] as? String)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Progress question", inColumn: "Waiting Response")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
    }
    // case-contract: test_task_rename_persists_and_rejects_blank_title | A rename waits for the real per-task operation lock, then persists across fresh CLI/XPC reads; rejecting a blank rename preserves the last valid title.
    func test_task_rename_persists_and_rejects_blank_title() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Before rename", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Before rename")
        let operationLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        let card = app.buttons.matching(NSPredicate(format: "label == %@", "Before rename")).firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 10))
        card.rightClick()
        let renameAction = element("rename-task-menu-item")
        XCTAssertTrue(renameAction.waitToExist(timeout: 5), "The task context menu has no rename action.")
        renameAction.click()

        let titleField = element("rename-task-title-field")
        XCTAssertTrue(titleField.waitToExist(timeout: 5))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("After rename")
        element("save-task-rename-button").click()
        XCTAssertTrue(card.waitToExist(timeout: 3), "The persisted title should remain unchanged while the task-operation lock is held.")
        try operationLock.release()
        XCTAssertTrue(app.buttons["After rename"].waitToExist(timeout: 10))

        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        assertCLIError(
            try runCLI(["task", "rename", taskID, "--title", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        attachScreenshot(named: "Renamed task remains unchanged after rejected blank rename")
    }
    // case-contract: test_task_title_is_selectable_and_matches_persisted_title | The conversation title has no copy button and its text is selectable: selecting and copying it places the task's exact persisted title on the pasteboard, including spaces, an ampersand and non-ASCII text, after a rename, and fresh CLI/XPC reads report the same title.
    func test_task_title_is_selectable_and_matches_persisted_title() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Before copy", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Before copy")
        let title = "Café & tea: ready ✓"
        _ = try runCLI(["task", "rename", taskID, "--title", title])
        let card = element("task-card-\(taskID.uppercased())")
        XCTAssertTrue(waitUntil({ card.exists }, timeout: 10), "The renamed task should appear on the board.")
        clickTaskCardTitle(card)
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10), "Opening the renamed task should show its conversation.")

        XCTAssertFalse(app.buttons["task-view-title-copy-button"].exists, "The conversation title should not have a copy button.")
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: element("task-view-title")) == title }, timeout: 10), "The header should show the persisted title.")
        NSPasteboard.general.clearContents()
        element("task-view-title").coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).doubleClick()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == "Café" }, timeout: 5), "Double-clicking the title's first word and copying should place that selected text on the pasteboard.")
        attachScreenshot(named: "Conversation title selected")
        XCTAssertEqual(try taskRecord(id: taskID)?["title"] as? String, title, "The copied title should match the persisted title.")
    }
    // case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, rejects an empty list, and waits for an active conversation turn; a stale Git-folder validation is rejected after a newer folder edit, and the newer roots remain saved.
    func test_task_roots_set_get_order_deduplication_and_validation() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Edit roots", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        openTask(named: "Edit roots")
        let taskID = try taskID(named: "Edit roots")

        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        let rootsEditProcess = try startCLIProcess([
            "task", "roots", "set", taskID,
            "--root", fixture.secondary.path,
            "--root", fixture.custom.path,
            "--root", fixture.primary.path,
        ])
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            try taskRecord(id: taskID)?["workspaceRoots"] as? [String],
            [fixture.primary.path],
            "Workspace roots should remain unchanged while a conversation turn holds its reservation."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        let rootsEditResult = try finishCLIProcess(rootsEditProcess)
        let expectedRoots = try XCTUnwrap((rootsEditResult["result"] as? [String: Any])?["workspaceRoots"] as? [String])
        let taskAfterEdit = try XCTUnwrap(taskRecord(named: "Edit roots"))
        XCTAssertEqual(taskAfterEdit["workspaceRoots"] as? [String], expectedRoots)
        assertOrderedRoots(expectedRoots)

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

        let concurrentTitle = "Concurrent root edit"
        let concurrent = try runCLI([
            "task", "create", "--title", concurrentTitle, "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let concurrentID = try XCTUnwrap(concurrent?["id"] as? String)
        relaunchApp()
        // A detached HEAD keeps the repository from being recognized without Git, so the
        // stale request is held inside Git while the newer one lands.
        let detached = WorkspaceFixture.root.appendingPathComponent("detached-head-\(UUID().uuidString)", isDirectory: true)
        try runGit(WorkspaceFixture.root, "clone", "--quiet", fixture.secondary.path, detached.path)
        try runGit(detached, "checkout", "--quiet", "--detach")
        let barrier = try GitConfigReadBarrier(repositoryURL: detached)
        var staleProcess: RunningCLIProcess?
        var barrierReleased = false
        var continueStaleProcess = false
        defer {
            if !barrierReleased { try? barrier.release() }
            if !continueStaleProcess, let process = staleProcess?.process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        staleProcess = try startCLIProcess(["task", "roots", "set", concurrentID, "--root", detached.path])
        try barrier.waitForReader()

        openTask(named: concurrentTitle)
        let newerRoots = try runCLI(["task", "roots", "set", concurrentID, "--root", fixture.custom.path])
        let newerRecord = try XCTUnwrap(newerRoots["result"] as? [String: Any])
        XCTAssertEqual(newerRecord["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(newerRecord["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual((newerRecord["repositoryWorktrees"] as? [Any])?.isEmpty, true)
        assertOrderedRoots([fixture.custom.path])

        try barrier.release()
        barrierReleased = true
        continueStaleProcess = true
        let stale = try finishCLIProcess(try XCTUnwrap(staleProcess), expectedStatus: 1)
        XCTAssertEqual((stale["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        let fresh = try XCTUnwrap(taskRecord(id: concurrentID))
        XCTAssertEqual(fresh["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(fresh["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual((fresh["repositoryWorktrees"] as? [Any])?.count, 0)
        attachScreenshot(named: "Edited ordered folders in task conversation")
    }
    // case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; UI selection waits for an active turn and persists a pending auto branch. While the conversation is empty, a prominent theme-colored heading names all selected repositories and updates as repository APIs add or replace context; compact repository labels remain in the header without a duplicate repository summary. Dark and light themes use distinct prominent title colors, the supporting model prompt sits below with generous spacing, and the generic Start a conversation heading is absent. Additional context folders remain identifiable. The task repository API remains available during an active turn, prepares a managed worktree inside the app data directory's task-worktrees folder, updates saved repository selection, replaces repository context safely, and the paired UI shows API additions/removals. The main assistant is instructed to list repositories through Playhouse, inspect listed source paths read-only without attaching them, and add repositories only when it needs a task worktree for changes or commits.
    func test_conversation_repository_picker_adds_repository_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI(["task", "create", "--title", "Header repository picker", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: "Header repository picker")
        element("add-conversation-repository-button").click()
        let search = element("conversation-repository-search")
        XCTAssertTrue(search.waitToExist(timeout: 5))
        search.click()
        search.typeText("suggested-parent")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-suggestion-changes").exists)
        XCTAssertTrue(element("conversation-repository-suggestion-secondary").exists)
        let suggestionResult = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        let suggestionPaths = try XCTUnwrap(suggestionResult?["repositories"] as? [String])
        let primarySuggestionIndex = try XCTUnwrap(suggestionPaths.firstIndex(of: fixture.primary.path))
        XCTAssertGreaterThan(primarySuggestionIndex, 0, "The primary repository should follow another suggestion so both arrow directions can be tested.")
        for _ in 0..<primarySuggestionIndex {
            search.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        }
        search.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        search.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        let suggestion = element("conversation-repository-suggestion-primary")
        XCTAssertTrue(suggestion.waitToExist(timeout: 10))
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        search.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            (try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.count,
            0,
            "The selected repository should not be attached until the conversation turn releases its reservation."
        )
        XCTAssertEqual(
            accessibleLabelOrValue(of: repositoryTitle()),
            "primary",
            "A Git workspace root should name its repository before the pending worktree is attached."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 10))
        let emptyTitle = repositoryTitle()
        XCTAssertEqual(accessibleLabelOrValue(of: emptyTitle), "primary", "The prominent empty-conversation title should identify the selected repository.")
        XCTAssertTrue(waitUntil({ repositoryTitleHasColor(emptyTitle, appearance: "dark") }, timeout: 5), "Dark appearance should render an orange repository title.")
        let conversationIcon = app.images["Conversation"]
        XCTAssertTrue(conversationIcon.waitToExist(timeout: 5))
        XCTAssertGreaterThan(conversationIcon.frame.minY - emptyTitle.frame.maxY, 40, "The conversation prompt should have breathing room below the repository title.")
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists, "The redundant Start a conversation heading should be removed.")
        XCTAssertFalse(element("working-folders-summary").exists, "Selected repositories already appear in the title and compact header labels.")
        _ = try runCLI(["settings", "set-appearance", "light"])
        XCTAssertTrue(waitUntil({ repositoryTitleHasColor(emptyTitle, appearance: "light") }, timeout: 5), "Light appearance should render an indigo repository title.")
        _ = try runCLI(["settings", "set-appearance", "dark"])
        XCTAssertTrue(waitUntil({ repositoryTitleHasColor(emptyTitle, appearance: "dark") }, timeout: 5), "Changing appearance should update the title color.")
        let title = element("task-view-title")
        XCTAssertTrue(title.waitToExist(timeout: 5))
        XCTAssertGreaterThan(badge.frame.minX, title.frame.maxX, "Repository badges should appear to the right of the task title.")
        // The badges sit beside the title, centered on the header's title and status lines together.
        let status = element("task-header-status")
        XCTAssertTrue(status.waitToExist(timeout: 5))
        let headerMidY = { (title.frame.minY + status.frame.maxY) / 2 }
        XCTAssertLessThan(abs(badge.frame.midY - headerMidY()), 4, "Repository badges should be vertically centered in the task header.")
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
        // Selecting the repository ran no Git; opening its settings works the defaults out.
        XCTAssertEqual(primary["branchFrom"] as? String, "")
        XCTAssertNil(primary["mergeTarget"])
        badge.click()
        app.activate()
        let branchValue = element("conversation-repository-branch-value")
        let branchFromValue = element("conversation-repository-branch-from-value")
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(branchValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(branchFromValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(mergeTargetValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "main"))
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "main"))
        XCTAssertEqual(accessibleLabelOrValue(of: branchValue), branch, app.debugDescription)
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: branchFromValue) == "main" }, timeout: 5), app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "main", app.debugDescription)
        XCTAssertTrue(app.staticTexts["Branch name"].exists)
        XCTAssertTrue(app.staticTexts["Branch from"].exists)
        XCTAssertTrue(app.staticTexts["Merge to"].exists)
        XCTAssertTrue(element("conversation-repository-branch-edit").exists)
        XCTAssertTrue(element("conversation-repository-branch-from-edit").exists)
        XCTAssertTrue(element("conversation-repository-merge-target-edit").exists)

        let apiReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var apiReservationReleased = false
        defer {
            if !apiReservationReleased { try? apiReservation.release() }
        }
        let apiAdded = try runCLI(["task", "repository", "add", taskID, "--repo", fixture.secondary.path])["result"] as? [String: Any]
        let apiRepositories = try XCTUnwrap(apiAdded?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(apiRepositories.count, 2)
        let secondary = try XCTUnwrap(apiRepositories.first { ($0["repositoryPath"] as? String) == fixture.secondary.path })
        XCTAssertEqual(secondary["isPending"] as? Bool, false, "The AI-facing API should return an editable worktree.")
        let managedWorktree = try XCTUnwrap(secondary["worktreePath"] as? String)
        XCTAssertNotEqual(managedWorktree, fixture.secondary.path)
        XCTAssertTrue(managedWorktree.hasPrefix(dataDirectory.appendingPathComponent("task-worktrees", isDirectory: true).path))
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 10), "Repository additions made through the AI API should appear in the open task header.")
        XCTAssertEqual(accessibleLabelOrValue(of: repositoryTitle()), "primary · secondary", "The prominent title should update when the API adds a repository.")
        XCTAssertFalse(element("working-folders-summary").exists, "Repository worktrees should not be repeated in a separate working-folders line.")
        let savedRepositories = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(savedRepositories?["lastSelectedRepositories"] as? [String], [fixture.primary.path, fixture.secondary.path])
        let replaced = try runCLI(["task", "repository", "replace", taskID, "--repo", fixture.secondary.path])["result"] as? [String: Any]
        XCTAssertEqual((replaced?["repositoryWorktrees"] as? [[String: Any]])?.compactMap { $0["repositoryPath"] as? String }, [fixture.secondary.path])
        XCTAssertTrue(element("conversation-repository-badge-secondary").exists)
        XCTAssertFalse(element("conversation-repository-badge-primary").exists, "API replacement should immediately remove the old repository badge.")
        XCTAssertEqual(accessibleLabelOrValue(of: repositoryTitle()), "secondary", "The title should track the active repository context.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String], [fixture.secondary.path])
        try apiReservation.release()
        apiReservationReleased = true

        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 5))
        composer.click()
        composer.typeText("Start working in the selected repositories.")
        element("send-message-button").click()
        let sentPrompt = app.textViews.matching(
            NSPredicate(format: "value == %@", "Start working in the selected repositories.")
        ).firstMatch
        XCTAssertTrue(sentPrompt.waitToExist(timeout: 10))
        XCTAssertFalse(repositoryTitle().exists, "The prominent repository title should leave the timeline once the conversation has messages.")
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists)
        let badgeAfterSend = element("conversation-repository-badge-secondary")
        XCTAssertTrue(badgeAfterSend.exists, "Compact repository badges should remain in the fixed task header after the timeline scrolls.")
        XCTAssertGreaterThan(badgeAfterSend.frame.minX, title.frame.maxX, "Repository badges should remain beside the task title after a message is sent.")
        XCTAssertLessThan(abs(badgeAfterSend.frame.midY - headerMidY()), 4, "Repository badges should stay vertically centered in the fixed task header after the timeline scrolls.")
    }
    // case-contract: test_conversation_repository_picker_add_and_replace_buttons | Each repository row in the header's Add repository picker adds the repository alongside the selected ones when the row or its plus button is clicked, and its Replace button removes every selected repository and attaches only that one; the task repository API reaches the same add and replace results, adding an attached repository again gives it another worktree on its own branch, and the saved repository selection follows. The catalog's shared Overlay atom contains both actions and reveals them on hover; the UI keeps them visible over the row and buttons and hides them on exit. Both buttons sit clear of the list's overlay scroller and each shows a hover highlight while the pointer is on it.
    func test_conversation_repository_picker_add_and_replace_buttons() throws {
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI(["task", "create", "--title", "Picker add and replace", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: "Picker add and replace")
        func attachedPaths() throws -> [String] {
            ((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]]) ?? []).compactMap { $0["repositoryPath"] as? String }
        }
        func search(_ text: String) {
            element("add-conversation-repository-button").click()
            let field = element("conversation-repository-search")
            XCTAssertTrue(field.waitToExist(timeout: 5))
            field.click()
            field.typeText(text)
        }
        // The plus button adds the first repository.
        search("primary")
        let primaryRow = element("conversation-repository-suggestion-primary")
        XCTAssertTrue(primaryRow.waitToExist(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-primary-add").exists, "The row buttons show only while hovering it.")
        primaryRow.hover()
        let primaryAdd = element("conversation-repository-suggestion-primary-add")
        XCTAssertTrue(primaryAdd.waitToExist(timeout: 5))
        XCTAssertTrue(primaryAdd.isHittable, "Hovering the row should reveal its plus button.")
        // The row's text stops 64 points (plus its 7-point padding) before its trailing edge, where the hover buttons sit.
        XCTAssertLessThanOrEqual(primaryRow.frame.maxX - primaryAdd.frame.minX, 71, "The plus button should sit in the space the row's text leaves clear.")
        // The list's overlay scroller covers about the last 15 points of each row.
        XCTAssertGreaterThanOrEqual(primaryRow.frame.maxX - primaryAdd.frame.maxX, 15, "The plus button should sit clear of the list's scroller.")
        attachScreenshot(named: "Hovered repository row shows its plus button")
        XCTAssertFalse(element("conversation-repository-suggestion-primary-replace").exists, "Replace is offered only once the task has repositories.")
        primaryAdd.click()
        XCTAssertTrue(element("conversation-repository-badge-primary").waitToExist(timeout: 10))
        // The row itself adds alongside.
        search("secondary")
        let secondaryRow = element("conversation-repository-suggestion-secondary")
        XCTAssertTrue(secondaryRow.waitToExist(timeout: 10))
        secondaryRow.hover()
        XCTAssertTrue(element("conversation-repository-suggestion-secondary-replace").waitToExist(timeout: 5))
        let secondaryAdd = element("conversation-repository-suggestion-secondary-add")
        let secondaryReplace = element("conversation-repository-suggestion-secondary-replace")
        XCTAssertTrue(secondaryAdd.exists)
        // Moving onto the revealed controls must not cause the row to lose hover.
        for target in [secondaryRow, secondaryAdd, secondaryReplace] {
            target.hover()
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.2)
                XCTAssertTrue(secondaryReplace.isHittable && secondaryAdd.isHittable, "Row actions must remain visible while the pointer is stationary.")
            }
        }
        attachScreenshot(named: "Hovered repository row shows Replace and Add once the task has a repository")
        attachElementScreenshot(element("conversation-repository-picker"), named: "Repository picker hover actions")
        // Each button draws a highlight behind its icon only while the pointer is on it.
        func meanDifference(_ first: NSImage, _ second: NSImage) -> CGFloat {
            guard let a = first.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let b = second.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
            let left = NSBitmapImageRep(cgImage: a), right = NSBitmapImageRep(cgImage: b)
            let width = min(left.pixelsWide, right.pixelsWide), height = min(left.pixelsHigh, right.pixelsHigh)
            var total: CGFloat = 0
            for x in 0..<width {
                for y in 0..<height {
                    guard let l = left.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let r = right.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    total += abs(l.redComponent - r.redComponent) + abs(l.greenComponent - r.greenComponent) + abs(l.blueComponent - r.blueComponent)
                }
            }
            return total / CGFloat(max(1, width * height * 3))
        }
        for (button, other) in [(secondaryAdd, secondaryReplace), (secondaryReplace, secondaryAdd)] {
            other.hover()
            Thread.sleep(forTimeInterval: 0.4)
            let resting = button.screenshot().image
            button.hover()
            Thread.sleep(forTimeInterval: 0.4)
            XCTAssertGreaterThan(meanDifference(resting, button.screenshot().image), 0.02, "\(button.identifier) should show a hover highlight.")
            attachElementScreenshot(element("conversation-repository-list"), named: "Hovering \(button.identifier) highlights it")
        }
        element("conversation-repository-search").hover()
        XCTAssertTrue(waitUntil({ !secondaryAdd.exists && !secondaryReplace.exists }, timeout: 5), "Actions should disappear after leaving the row.")
        secondaryRow.hover()
        XCTAssertTrue(secondaryAdd.waitToExist(timeout: 5))
        secondaryRow.click()
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-primary").exists, "Adding keeps the other selected repositories.")
        XCTAssertEqual(Set(try attachedPaths()), Set([fixture.primary.path, fixture.secondary.path]))
        attachScreenshot(named: "Clicking the row added secondary alongside primary")
        // Adding an attached repository again gives it another worktree, with a chip per worktree.
        let again = try XCTUnwrap((try runCLI(["task", "repository", "add", taskID, "--repo", fixture.secondary.path])["result"] as? [String: Any])?["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(again.compactMap { $0["repositoryPath"] as? String }.filter { $0 == fixture.secondary.path }.count, 2)
        let secondaryBranches = again.filter { $0["repositoryPath"] as? String == fixture.secondary.path }.compactMap { $0["branch"] as? String }
        XCTAssertEqual(Set(secondaryBranches).count, 2, "Each worktree of a repository has its own branch.")
        for branch in secondaryBranches {
            XCTAssertTrue(element("conversation-repository-badge-secondary-\(branch)").waitToExist(timeout: 10), "Each secondary worktree gets its own chip.")
        }
        XCTAssertFalse(element("conversation-repository-badge-secondary").exists)
        // Replace removes every selected repository.
        search("alternate")
        let alternateRow = element("conversation-repository-suggestion-alternate")
        XCTAssertTrue(alternateRow.waitToExist(timeout: 10))
        alternateRow.hover()
        let alternateReplace = element("conversation-repository-suggestion-alternate-replace")
        XCTAssertTrue(alternateReplace.waitToExist(timeout: 5))
        XCTAssertLessThanOrEqual(alternateRow.frame.maxX - alternateReplace.frame.minX, 71, "Replace and plus should both sit in the space the row's text leaves clear.")
        alternateReplace.hover()
        attachScreenshot(named: "Hovering Replace on alternate")
        alternateReplace.click()
        XCTAssertTrue(element("conversation-repository-badge-alternate").waitToExist(timeout: 10))
        // Replace removes the worktrees one by one; the last secondary one is briefly the plain chip.
        XCTAssertTrue(waitUntil({ (try? attachedPaths().map { URL(fileURLWithPath: $0).lastPathComponent }) == ["alternate"] }, timeout: 15),
                      "Replace should leave only alternate attached: \(String(describing: try? attachedPaths()))")
        XCTAssertTrue(waitUntil({ !self.element("conversation-repository-badge-primary").exists
            && !self.element("conversation-repository-badge-secondary").exists
            && secondaryBranches.allSatisfy { !self.element("conversation-repository-badge-secondary-\($0)").exists } }, timeout: 10), "Replace should remove the previous repository badges.")
        attachScreenshot(named: "Replace left only alternate attached")
    }
    // case-contract: test_task_repository_settings_validate_persist_and_lock_after_start | Pending repository branch, merge-from, and merge-to settings wait for an active conversation turn, then persist across fresh CLI/XPC reads; a field saved while the repository's default branch-from and merge target are still being worked out waits for them and saves the typed value alongside the resolved defaults; invalid settings leave prior values intact, and settings are locked after worktree creation. Each setting is edited in place: the pencil beside a value opens an inline field with a checkmark that saves only that field and keeps the editor open on the saved value, and clicking outside the field or pressing Escape dismisses the edit without saving. The settings popover is wider than before with a larger title, and the repository chip's remove button is a larger target.
    func test_task_repository_settings_validate_persist_and_lock_after_start() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let title = "Repository settings through UI"
        let created = try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: title)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 5))
        let removeBadgeButton = element("remove-conversation-repository-primary")
        XCTAssertGreaterThanOrEqual(removeBadgeButton.frame.width, 20, "The repository chip's remove button should be an easy target.")
        XCTAssertGreaterThanOrEqual(removeBadgeButton.frame.height, 20, "The repository chip's remove button should be an easy target.")
        attachScreenshot(named: "Repository chip with enlarged remove button")

        // Opening the settings works the defaults out; holding the task's operation lock keeps
        // them from being saved, so a field saved meanwhile has to wait for them.
        let undecided = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(undecided["branchFrom"] as? String, "")
        XCTAssertNil(undecided["mergeTarget"])
        let operationLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var operationLockReleased = false
        defer {
            if !operationLockReleased { try? operationLock.release() }
        }
        badge.click()
        let initialBranchValue = element("conversation-repository-branch-value")
        let branchEdit = element("conversation-repository-branch-edit")
        XCTAssertTrue(initialBranchValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(branchEdit.exists)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String, "",
                       "The defaults can't be saved while the task's operation lock is held.")
        branchEdit.click()
        replaceText(element("conversation-repository-branch"), with: "saved-before-defaults")
        element("conversation-repository-branch-save").click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
        XCTAssertFalse(element("codex-chat-error").exists, "A field saved before the defaults are known must wait for them, not fail.")
        try operationLock.release()
        operationLockReleased = true
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branch", expected: "saved-before-defaults"))
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "main"))
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "main"))
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("conversation-repository-branch-from-value")) == "main" }, timeout: 5),
                      "The popover should show the resolved branch-from once it is saved.")
        XCTAssertEqual(accessibleLabelOrValue(of: initialBranchValue), "saved-before-defaults")
        XCTAssertFalse(element("codex-chat-error").exists, app.debugDescription)
        attachScreenshot(named: "A branch saved before the defaults resolved keeps them")
        let initialBranch = "saved-before-defaults"
        let initialBranchFrom = "main"
        let settingsTitle = element("conversation-repository-settings-title")
        XCTAssertGreaterThanOrEqual(app.popovers.firstMatch.frame.width, 340, "The repository settings popover should be roomier than before.")
        XCTAssertGreaterThanOrEqual(settingsTitle.frame.height, 17, "The repository settings title should use a larger font.")
        XCTAssertLessThan(branchEdit.frame.minX - initialBranchValue.frame.maxX, 6, "The edit pencil should sit right beside its value.")
        XCTAssertGreaterThanOrEqual(branchEdit.frame.width, 20, "The edit pencil should be an easy target.")
        XCTAssertFalse(element("save-conversation-repository-button").exists, "Per-field checkmarks replace the popover-wide Save button.")
        XCTAssertFalse(element("remove-conversation-repository-button").exists, "Removal moved from the popover to the repository chip badge.")
        attachScreenshot(named: "Repository settings popover with pencils beside each value")
        attachRegionScreenshot([initialBranchValue, branchEdit], named: "Repository branch value and edit pencil")
        branchEdit.click()
        let branchField = element("conversation-repository-branch")
        let branchSave = element("conversation-repository-branch-save")
        XCTAssertTrue(branchField.waitToExist(timeout: 5))
        XCTAssertTrue(branchSave.exists, "Editing a value should show a confirmation checkmark.")
        XCTAssertGreaterThan(branchSave.frame.minX, branchField.frame.minX, "The checkmark should sit inside the field's trailing edge.")
        XCTAssertLessThan(abs(branchSave.frame.midY - branchField.frame.midY), 6, "The checkmark should be inside the field.")
        XCTAssertFalse(element("conversation-repository-branch-from-save").exists, "Only the field being edited shows a checkmark.")
        replaceText(branchField, with: "invalid branch")
        attachScreenshot(named: "Inline branch edit with its confirmation checkmark")
        attachRegionScreenshot([branchField, branchSave], named: "Inline branch field and confirmation control")
        branchSave.click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "Invalid branch settings should be shown in the conversation.")
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String, initialBranch)
        XCTAssertTrue(branchField.exists, "A rejected value should stay open for correction.")

        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        replaceText(branchField, with: "conversation-edited")
        branchSave.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String,
            initialBranch,
            "Repository settings should remain unchanged while a conversation turn holds its reservation."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branch", expected: "conversation-edited"))
        XCTAssertTrue(waitForDisappearance(branchField), "A confirmed value should leave edit mode.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("conversation-repository-branch-value")), "conversation-edited", "The editor should stay open on the saved value.")

        element("conversation-repository-branch-from-edit").click()
        let branchFromField = element("conversation-repository-branch-from")
        XCTAssertTrue(branchFromField.waitToExist(timeout: 5))
        replaceText(branchFromField, with: "discarded-edit")
        settingsTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForDisappearance(branchFromField), "Clicking outside the field should dismiss the edit.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("conversation-repository-branch-from-value")), initialBranchFrom, "A dismissed edit must not change the shown value.")
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String, initialBranchFrom, "A dismissed edit must not be saved.")
        attachScreenshot(named: "Clicking outside the field dismisses the edit unsaved")

        element("conversation-repository-branch-from-edit").click()
        XCTAssertTrue(branchFromField.waitToExist(timeout: 5))
        replaceText(branchFromField, with: "escaped-edit")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(branchFromField), "Escape should dismiss the edit.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("conversation-repository-branch-from-value")), initialBranchFrom, "An escaped edit must not change the shown value.")
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String, initialBranchFrom, "An escaped edit must not be saved.")
        attachScreenshot(named: "Escape dismisses the edit unsaved")

        element("conversation-repository-branch-from-edit").click()
        XCTAssertTrue(branchFromField.waitToExist(timeout: 5))
        replaceText(branchFromField, with: "branch-source")
        element("conversation-repository-branch-from-save").click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "branch-source"))
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "conversation-edited", "Saving one field must keep the others.")

        XCTAssertTrue(waitForDisappearance(branchFromField))
        element("conversation-repository-merge-target-edit").click()
        let mergeTargetField = element("conversation-repository-merge-target")
        let mergeTargetSave = element("conversation-repository-merge-target-save")
        XCTAssertTrue(mergeTargetField.waitToExist(timeout: 5))
        replaceText(mergeTargetField, with: "branch-source")
        mergeTargetSave.click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "branch-source"))
        XCTAssertTrue(waitForDisappearance(mergeTargetField))
        element("conversation-repository-merge-target-edit").click()
        XCTAssertTrue(mergeTargetField.waitToExist(timeout: 5))
        replaceText(mergeTargetField, with: "missing-local-branch")
        mergeTargetSave.click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "An invalid merge target should be shown in the conversation.")
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["mergeTarget"] as? String,
            "branch-source",
            "Rejecting an invalid merge target must preserve the saved value."
        )
        replaceText(mergeTargetField, with: "branch-source")
        mergeTargetSave.click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "branch-source"))
        XCTAssertTrue(waitForDisappearance(mergeTargetField), "A successful save should leave edit mode.")
        attachScreenshot(named: "Saved repository settings stay visible in the open popover")
        // Reopen the popover so the values come from the saved record.
        element("task-view-title").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForDisappearance(element("conversation-repository-branch-value")), "Clicking outside the popover should close it.")
        badge.click()
        app.activate()
        let branchValue = element("conversation-repository-branch-value")
        let branchFromValue = element("conversation-repository-branch-from-value")
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(branchValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(branchFromValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertTrue(mergeTargetValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchValue), "conversation-edited", app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchFromValue), "branch-source", app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "branch-source", app.debugDescription)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["isPending"] as? Bool, true)

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
        badge.click()
        XCTAssertTrue(element("conversation-repository-settings-locked").waitToExist(timeout: 5))
        XCTAssertFalse(element("conversation-repository-branch-edit").exists)
        XCTAssertFalse(element("conversation-repository-branch-save").exists)
        assertCLIError(
            try runCLI([
                "task", "repository", "edit", taskID,
                "--repo", fixture.primary.path,
                "--branch", "changed-after-start",
                "--branch-from", "branch-source",
                "--merge-target", "branch-source",
            ], expectedStatus: 1),
            code: "invalid_transition"
        )
        let final = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(final["branch"] as? String, "conversation-edited")
        XCTAssertEqual(final["branchFrom"] as? String, "branch-source")
        XCTAssertEqual(final["mergeTarget"] as? String, "branch-source")
        XCTAssertEqual(final["isPending"] as? Bool, false)
    }
    // case-contract: test_task_repository_branch_from_fetches_remote_branch | A branch-from that exists only on a Git remote and was never fetched is fetched when repository settings are saved, and the pending record stores its remote-tracking branch; a branch-from missing locally and on every remote is rejected without changing the saved settings; a remote that can't be reached reports the fetch failure instead of a missing branch and also keeps the saved settings; starting the task fetches the remote branch again, so its worktree starts from the remote's latest commit even after the remote branch moved ahead, without making the remote branch the task branch's upstream.
    func test_task_repository_branch_from_fetches_remote_branch() throws {
        let remoteBranch = "remote-only/branch-from"
        let trackingRef = "refs/remotes/origin/\(remoteBranch)"
        let remote = runDirectory.appendingPathComponent("branch-from-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should use a fresh owned bare remote.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(remote, "init", "--bare")
        let remoteCommit = try runGitOutput(
            fixture.primary, "commit-tree", "main^{tree}", "-p", "main", "-m", "Create remote-only branch-from fixture commit"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        try runGit(fixture.primary, "push", "--quiet", "origin", "main", "\(remoteCommit):refs/heads/\(remoteBranch)")
        // Pushing records the remote-tracking ref; drop it so the branch exists only on the remote.
        try runGit(fixture.primary, "update-ref", "-d", trackingRef)
        let trackingRefs = try runGitOutput(fixture.primary, "for-each-ref", "--format=%(refname)", trackingRef)
        XCTAssertEqual(trackingRefs.trimmingCharacters(in: .whitespacesAndNewlines), "", "The remote branch must start unfetched.")

        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let title = "Remote branch-from through UI"
        let created = try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        // This case is about the task's base. Manual mode keeps Review from publishing the task
        // branch to the fixture origin and opening a pull request through an unfixtured gh.
        try setPullRequestMode("manual", taskID: taskID)
        openTask(named: title)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 5))

        badge.click()
        element("conversation-repository-branch-from-edit").click()
        let branchFromField = element("conversation-repository-branch-from")
        let branchFromSave = element("conversation-repository-branch-from-save")
        XCTAssertTrue(branchFromField.waitToExist(timeout: 5))
        replaceText(branchFromField, with: remoteBranch)
        attachScreenshot(named: "Branch-from names a branch that exists only on the remote")
        branchFromSave.click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "origin/\(remoteBranch)"))
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", trackingRef).trimmingCharacters(in: .whitespacesAndNewlines), remoteCommit)
        let localBranches = try runGitOutput(fixture.primary, "for-each-ref", "--format=%(refname)", "refs/heads/\(remoteBranch)")
        XCTAssertEqual(localBranches.trimmingCharacters(in: .whitespacesAndNewlines), "", "Fetching must not create a local branch.")
        XCTAssertTrue(waitForDisappearance(branchFromField), "A successful save should leave edit mode.")

        let branchFromValue = element("conversation-repository-branch-from-value")
        XCTAssertTrue(branchFromValue.waitToExist(timeout: 5), app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchFromValue), "origin/\(remoteBranch)", app.debugDescription)
        attachScreenshot(named: "Remote branch-from is fetched and saved as its remote-tracking branch")

        element("conversation-repository-branch-from-edit").click()
        XCTAssertTrue(branchFromField.waitToExist(timeout: 5))
        replaceText(branchFromField, with: "missing-everywhere/branch")
        branchFromSave.click()
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 10), "A branch-from missing locally and on the remote should be shown in the conversation.")
        XCTAssertTrue(error.label.contains("missing-everywhere/branch"), error.label)
        attachScreenshot(named: "Branch-from missing locally and on the remote is rejected")
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String,
            "origin/\(remoteBranch)",
            "Rejecting a missing branch-from must preserve the saved value."
        )
        XCTAssertTrue(branchFromField.exists, "A rejected value should stay open for correction.")

        try runGit(fixture.primary, "remote", "set-url", "origin", runDirectory.appendingPathComponent("unreachable-origin.git").path)
        replaceText(branchFromField, with: "unfetched/branch")
        branchFromSave.click()
        XCTAssertTrue(
            waitUntil({ error.exists && error.label.contains("couldn't fetch 'unfetched/branch' from origin") }, timeout: 10),
            "A fetch failure should be reported as such, not as a missing branch: \(error.label)"
        )
        attachScreenshot(named: "Unreachable remote reports the fetch failure")
        try runGit(fixture.primary, "remote", "set-url", "origin", remote.path)
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String,
            "origin/\(remoteBranch)",
            "A failed fetch must preserve the saved value."
        )
        // Escape first cancels the open field edit (#173), then a second Escape closes the editor.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(branchFromField), "Escape should first cancel the open field edit.")
        XCTAssertTrue(branchFromValue.exists, "Cancelling the field edit should leave the editor open.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(branchFromValue), "Dismissing the editor should close it before the turn starts.")

        // The remote branch moves ahead after it was fetched; starting must use the newer commit.
        let newerCommit = try runGitOutput(
            fixture.primary, "commit-tree", "main^{tree}", "-p", remoteCommit, "-m", "Advance remote-only branch-from fixture"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(fixture.primary, "push", "--quiet", "origin", "\(newerCommit):refs/heads/\(remoteBranch)")
        try runGit(fixture.primary, "update-ref", trackingRef, remoteCommit)

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
        let started = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(started["isPending"] as? Bool, false)
        XCTAssertEqual(started["branchFrom"] as? String, "origin/\(remoteBranch)")
        let worktree = URL(fileURLWithPath: try XCTUnwrap(started["worktreePath"] as? String), isDirectory: true)
        let taskBranch = try XCTUnwrap(started["branch"] as? String)
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), newerCommit)
        let upstream = try runGitOutput(worktree, "config", "--default", "", "--get", "branch.\(taskBranch).remote")
        XCTAssertEqual(upstream.trimmingCharacters(in: .whitespacesAndNewlines), "", "The remote branch-from must not become the task branch's upstream.")
    }
}

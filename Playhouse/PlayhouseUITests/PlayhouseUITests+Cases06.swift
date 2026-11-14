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
    // case-contract: test_waiting_response_task_moves_to_review_manually | A task in Waiting Response moves to Review through the CLI and on the board, both from its card's Move to Review context-menu item, which only Waiting Response cards offer, and by dragging the card onto the Review column. The move runs the same review gate as a completed outcome: local changes on a PR-linked worktree are committed before the task reaches Review. It clears the waiting status, persists across a fresh CLI/XPC read, keeps the linked pull request, returns a task already in Review unchanged, and the moved task can still complete to Done. A Backlog task is rejected and keeps its status; a task whose turn is still running while it shows Waiting Response is rejected and keeps both its status and its uncommitted changes; and when the pull request sync fails, the move reports the error, shown on the board as an alert, and leaves the task in Waiting Response; once GitHub reports the pull request merged, a retry commits local work, skips syncing the merged branch even though its remote is unreachable, and moves the task to Review. Each transition into Waiting Response plays Ping and each transition into Review plays Glass; rejected and repeated moves play no sound.
    func test_waiting_response_task_moves_to_review_manually() throws {
        let questionFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-status-transition-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: questionFixture.path))
        codexFixtureExecutable = questionFixture.path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [321]).merging(Self.prCheckCooldownEnvironment) { $1 }
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        // A PR-linked repository task that has already been worked on.
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Manual review menu", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let menuTaskID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(
            try runCLI([
                "conversation", "send", menuTaskID, "--message", "Please ask your questions.", "--mode", "plan",
                "--answer", "color=Blue", "--answer", "token=fixture-secret"
            ])["ok"] as? Bool,
            true
        )
        XCTAssertEqual(try taskRecord(id: menuTaskID)?["status"] as? String, "Waiting Response")
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: menuTaskID, number: 321, url: "https://github.com/playhouse-test/fixture/pull/321")
        let record = try XCTUnwrap((try taskRecord(id: menuTaskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        try createTaskFixture(title: "Manual review backlog", roots: [fixture.alternate.path])
        let backlogTaskID = try taskID(named: "Manual review backlog")
        assertCLIError(try runCLI(["task", "move", backlogTaskID, "Review"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try taskRecord(id: backlogTaskID)?["status"] as? String, "Backlog")
        element("task-card-\(backlogTaskID)").rightClick()
        XCTAssertTrue(element("rename-task-menu-item").waitToExist(timeout: 5))
        XCTAssertFalse(element("move-task-to-review-menu-item").exists, "Only Waiting Response cards offer Move to Review.")
        app.typeKey(.escape, modifierFlags: [])

        // A pending blocking question shows Waiting Response while its turn still runs.
        openTask(named: "Manual review menu")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: menuTaskID)?["status"] as? String, "Waiting Response")
        try "Waiting turn output.\n".write(to: worktree.appendingPathComponent("manual-review.txt"), atomically: true, encoding: .utf8)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Manual review menu", inColumn: "Waiting Response")

        let menuCard = element("task-card-\(menuTaskID)")
        let moveToReview = element("move-task-to-review-menu-item")
        let rejection = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        let soundsBeforeRejection = try diagnosticEvents().filter { $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == menuTaskID }.count
        menuCard.rightClick()
        XCTAssertTrue(moveToReview.waitToExist(timeout: 5), "A Waiting Response card should offer Move to Review.")
        moveToReview.click()
        XCTAssertTrue(rejection.waitToExist(timeout: 10), "Moving a task whose turn is still running should explain the rejection.")
        XCTAssertTrue(rejection.staticTexts.matching(NSPredicate(format: "value == %@", "Couldn't move task to Review")).firstMatch.exists)
        XCTAssertTrue(rejection.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "still running")).firstMatch.exists)
        attachScreenshot(named: "Move to Review is rejected while the question's turn still runs")
        rejection.buttons["OK"].click()
        XCTAssertEqual(try taskRecord(id: menuTaskID)?["status"] as? String, "Waiting Response")
        XCTAssertEqual(try diagnosticEvents().filter { $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == menuTaskID }.count, soundsBeforeRejection)
        XCTAssertTrue(try runGitOutput(worktree, "status", "--porcelain", "--untracked-files=all").contains("manual-review.txt"),
                      "A rejected move must leave the running turn's files untouched.")
        assertTaskVisible("Manual review menu", inColumn: "Waiting Response")

        openTask(named: "Manual review menu")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 5))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
        // The status reads Waiting Response before the turn releases the task, so wait for the daemon.
        let threadID = try XCTUnwrap(try taskRecord(id: menuTaskID)?["codexThreadID"] as? String)
        XCTAssertTrue(waitUntil({
            let runtime = (try? self.runCLI(["conversation", "runtime"]))?["result"] as? [String: Any]
            return runtime != nil && !((runtime?["activeThreadIDs"] as? [String] ?? []).contains(threadID))
                && (try? self.taskRecord(id: menuTaskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 30), "The answered turn should finish in Waiting Response.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))

        // A pull request sync that fails reports the error and leaves the task waiting.
        let missingRemote = runDirectory.appendingPathComponent("manual-review-missing-origin.git", isDirectory: true)
        try runGit(fixture.primary, "remote", "add", "origin", missingRemote.path)
        addTeardownBlock { [self] in
            // The case removes it itself on success; only clean up after an early failure.
            if (try? runGitOutput(fixture.primary, "remote"))?.split(whereSeparator: \.isNewline).contains("origin") == true {
                try? runGit(fixture.primary, "remote", "remove", "origin")
            }
        }
        menuCard.rightClick()
        XCTAssertTrue(moveToReview.waitToExist(timeout: 5))
        moveToReview.click()
        XCTAssertTrue(rejection.waitToExist(timeout: 15), "A failed pull request sync should be shown to the user.")
        XCTAssertTrue(rejection.staticTexts.matching(NSPredicate(format: "value == %@", "Couldn't move task to Review")).firstMatch.exists)
        XCTAssertFalse(rejection.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "still running")).firstMatch.exists,
                       "This alert should report the sync failure, not the finished turn.")
        XCTAssertTrue(rejection.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "origin")).firstMatch.exists,
                      "The alert should carry the git error for the unreachable PR remote.")
        attachScreenshot(named: "A failed pull request sync keeps the task in Waiting Response")
        rejection.buttons["OK"].click()
        XCTAssertEqual(try taskRecord(id: menuTaskID)?["status"] as? String, "Waiting Response")
        assertTaskVisible("Manual review menu", inColumn: "Waiting Response")

        // Once GitHub reports the PR merged, its gone branch is not synced and the retry reaches Review.
        try "Work after the failed move.\n".write(to: worktree.appendingPathComponent("merged-retry.txt"), atomically: true, encoding: .utf8)
        try "321=merged\n".write(toFile: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]), atomically: true, encoding: .utf8)
        menuCard.rightClick()
        XCTAssertTrue(moveToReview.waitToExist(timeout: 5))
        attachScreenshot(named: "Waiting Response card context menu offers Move to Review")
        moveToReview.click()
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: menuTaskID)?["status"] as? String) == "Review"
        }, timeout: 15), "Move to Review should persist the Review status.")
        assertTaskVisible("Manual review menu", inColumn: "Review")
        XCTAssertNil(try taskRecord(id: menuTaskID)?["statusMessage"] as? String)
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain", "--untracked-files=all"), "",
                       "Moving to Review should commit the PR-linked worktree's local changes like a completed turn.")
        XCTAssertTrue(try runGitOutput(worktree, "show", "--name-only", "--format=%s", "HEAD").contains("merged-retry.txt"),
                      "The merged retry should commit the work left after the failed move.")
        XCTAssertTrue(try runGitOutput(worktree, "log", "--name-only", "--format=%s", "-2").contains("manual-review.txt"))
        XCTAssertEqual((try taskRecord(id: menuTaskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"] as? Int, 321)
        XCTAssertFalse(rejection.exists, "A merged pull request should not raise a sync alert.")
        attachScreenshot(named: "A merged pull request's task moves to Review")
        try runGit(fixture.primary, "remote", "remove", "origin")

        // Drag and drop: a Waiting Response card dropped on the Review column.
        try createTaskFixture(title: "Manual review drag", roots: [fixture.secondary.path])
        let dragTaskID = try taskID(named: "Manual review drag")
        XCTAssertEqual(
            try runCLI([
                "conversation", "send", dragTaskID, "--message", "Please ask your questions.", "--mode", "plan",
                "--answer", "color=Blue", "--answer", "token=fixture-secret"
            ])["ok"] as? Bool,
            true
        )
        XCTAssertEqual(try taskRecord(id: dragTaskID)?["status"] as? String, "Waiting Response")
        assertTaskVisible("Manual review drag", inColumn: "Waiting Response")
        attachScreenshot(named: "Waiting Response card before dragging it to Review")
        let reviewColumn = element("column-review")
        XCTAssertTrue(reviewColumn.waitToExist(timeout: 5))
        // The card has just moved columns; a drag that starts mid-animation grabs empty board.
        XCTAssertTrue(waitForStableFrame(element("task-card-\(dragTaskID)")), "The card should settle in Waiting Response before the drag.")
        element("task-card-\(dragTaskID)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: reviewColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: dragTaskID)?["status"] as? String) == "Review"
        }, timeout: 15), "Dropping a Waiting Response card on Review should persist the Review status.")
        assertDoneDrawerResting("after a Waiting Response card is dropped on Review")
        assertTaskVisible("Manual review drag", inColumn: "Review")
        assertTaskVisible("Manual review menu", inColumn: "Review")
        XCTAssertFalse(element("column-heading-waiting-response").exists, "Waiting Response hides once both tasks moved to Review.")
        attachScreenshot(named: "Both manually moved tasks rest in Review")

        XCTAssertEqual(
            (try runCLI(["task", "move", dragTaskID, "Review"])["result"] as? [String: Any])?["status"] as? String,
            "Review",
            "A task already in Review is returned unchanged."
        )
        let soundEvents = try diagnosticEvents().filter {
            $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == dragTaskID
        }
        XCTAssertEqual(soundEvents.compactMap { $0["sound"] as? String }, ["Ping", "Ping", "Glass"],
                       "The waiting and review transitions play distinct sounds; a repeated move is silent.")
        moveTaskToDone(taskID: dragTaskID)
        assertTaskVisible("Manual review menu", inColumn: "Review")
        XCTAssertEqual(try taskRecord(id: backlogTaskID)?["status"] as? String, "Backlog")
    }
    // case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed, in-progress, and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; provider processes started from the CLI/XPC service or the app's composer inherit that app's bridge service name and store directory, and an outcome reported with exactly that inherited environment reaches the task. A successful turn without an outcome receives up to five private status nudges that each offer in-progress alongside completed and waiting-response; a completed report during a nudge moves the task to Review, a waiting-response report during a nudge stops the loop and leaves the task in Waiting Response, and no report after every nudge marks the task Blocked rather than Waiting Response, since the user was never asked anything. The board shows progress details and places completed tasks in Review and waiting outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work. They place the outcome call, still the final CLI action, before the user-visible final reply, which ends the turn so it never ends on a tool call, and they tell the agent not to repeat an answer after a no-visible-output notice. Only an explicit completed outcome reaches Review. When a final answer ends with the outcome command written as text instead of run, the final answer, fresh history, and transcript hide that command, and it counts as the turn's outcome only when it names this task. A status nudge Playhouse sent shows its prompt and the agent's reply in Codex history and the visible transcript, including after later ordinary turns. Fresh Codex history after those nudges also retains the latest ordinary-turn diff while showing the nudge replies. Completed and waiting-response outcomes start Glass and Ping respectively when their turns settle.
    func test_task_progress_reports_publish_persist_and_clear() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Progress reports", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Progress reports")
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-progress-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["conversation", "send", taskID, "--message", "Work on this task."]
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        environment["CODEX_HOME"] = dataDirectory.appendingPathComponent("codex-home").path
        environment["PLAYHOUSE_WORKTREE_LABEL"] = "Playhouse UI Test Worktree"
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = executable.path
        process.environment = environment
        let stdout = DrainingPipe()
        let stderr = DrainingPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        try process.run()

        defer {
            if process.isRunning {
                try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The Codex fixture should hold the conversation turn open.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")

        let built = try runCLI(["task", "progress", "publish", taskID, "--type", "building", "--detail", "Compiling the app"])
        XCTAssertEqual((built["result"] as? [String: Any])?["progressLabel"] as? String, "Building")
        let reportID = "task-progress-report-\(taskID.uppercased())"
        let report = element(reportID)
        let label = element("task-progress-label-\(taskID.uppercased())")
        let icon = element("task-progress-icon-\(taskID.uppercased())")
        XCTAssertTrue(waitUntil({
            report.exists && report.label.contains("Building") && report.label.contains("Compiling the app")
        }, timeout: 10), "The board card should expose the Building label and detail.")
        XCTAssertTrue(waitUntil({ icon.exists && icon.label == "hammer" }, timeout: 10), "The Building SF Symbol should be exposed as a visible, accessible image.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "Publishing progress must not change lifecycle state.")
        XCTAssertEqual(try taskRecord(id: taskID)?["progressDetail"] as? String, "Compiling the app", "A fresh CLI/XPC connection should read the persisted report.")

        let custom = try runCLI(["task", "progress", "custom", taskID, "--label", "Checking migration", "--detail", "Reading the stored task data"])
        let customRecord = try XCTUnwrap(custom["result"] as? [String: Any])
        XCTAssertNil(customRecord["progressType"] as? String)
        XCTAssertEqual(customRecord["progressLabel"] as? String, "Checking migration")
        XCTAssertTrue(waitUntil({
            report.exists && report.label.contains("Checking migration") && report.label.contains("Reading the stored task data")
        }, timeout: 10), "The task card should update to a custom report with its detail and generic icon.")
        XCTAssertTrue(waitUntil({ icon.exists && icon.label == "sparkle" }, timeout: 10), "The custom report should expose its generic SF Symbol as a visible, accessible image.")
        assertCLIError(try runCLI(["task", "progress", "publish", taskID, "--type", "unknown"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["task", "progress", "custom", taskID, "--label", " "], expectedStatus: 2), code: "invalid_argument")

        let cleared = try runCLI(["task", "progress", "clear", taskID])
        XCTAssertNil((cleared["result"] as? [String: Any])?["progressLabel"])
        relaunchApp()
        XCTAssertTrue(waitForDisappearance(label), "Clearing a report should remove its secondary row from the card.")
        _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing"])
        relaunchApp()
        let completedOutcome = try runCLI(["task", "outcome", taskID, "completed"])
        let completedOutcomeRecord = try XCTUnwrap(completedOutcome["result"] as? [String: Any])
        XCTAssertEqual(completedOutcomeRecord["outcome"] as? String, "completed")
        XCTAssertEqual(completedOutcomeRecord["taskStatus"] as? String, "In Progress", "Outcome should be applied only after the turn completes.")
        try "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        process.waitUntilExit()
        let output = stdout.drainedText()
        let errorOutput = stderr.drainedText()
        XCTAssertEqual(process.terminationStatus, 0, "The fixture conversation should finish successfully: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        XCTAssertTrue(response["ok"] as? Bool == true)
        assertTaskVisible("Progress reports", inColumn: "Review")

        let resumedProcess = Process()
        resumedProcess.executableURL = cliURL
        resumedProcess.arguments = ["conversation", "send", taskID, "--message", "Continue on this task."]
        resumedProcess.environment = environment
        let resumedStdout = DrainingPipe()
        let resumedStderr = DrainingPipe()
        resumedProcess.standardOutput = resumedStdout.pipe
        resumedProcess.standardError = resumedStderr.pipe
        try resumedProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The follow-up should resume the existing fixture thread.")
        let waitingOutcome = try runCLI(["task", "outcome", taskID, "waiting-response"])
        let waitingOutcomeRecord = try XCTUnwrap(waitingOutcome["result"] as? [String: Any])
        XCTAssertEqual(waitingOutcomeRecord["outcome"] as? String, "waiting-response")
        XCTAssertEqual(waitingOutcomeRecord["taskStatus"] as? String, "In Progress")
        try "Release the resumed turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        resumedProcess.waitUntilExit()
        let resumedOutput = resumedStdout.drainedText()
        let resumedError = resumedStderr.drainedText()
        XCTAssertEqual(resumedProcess.terminationStatus, 0, "The resumed fixture conversation should finish successfully: \(resumedOutput) \(resumedError)")
        let resumedResponseLine = try XCTUnwrap(resumedOutput.split(whereSeparator: \.isNewline).last)
        let resumedResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resumedResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(resumedResponse["ok"] as? Bool == true)
        assertTaskVisible("Progress reports", inColumn: "Waiting Response")
        XCTAssertEqual(try diagnosticEvents().filter { $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == taskID }.compactMap { $0["sound"] as? String }, ["Glass", "Ping"])

        let omittedProcess = Process()
        omittedProcess.executableURL = cliURL
        omittedProcess.arguments = ["conversation", "send", taskID, "--message", "A turn without an outcome."]
        omittedProcess.environment = environment
        let omittedStdout = DrainingPipe()
        let omittedStderr = DrainingPipe()
        omittedProcess.standardOutput = omittedStdout.pipe
        omittedProcess.standardError = omittedStderr.pipe
        try omittedProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The no-outcome turn should resume the existing fixture thread.")
        for nudgeIndex in 0...Self.maxOutcomeContinuations {
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "The fallback status should be deferred until every private nudge finishes.")
            try "Release turn \(nudgeIndex + 1).\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
            if nudgeIndex < Self.maxOutcomeContinuations {
                XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The fixture should finish the current unreported turn.")
                XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "Playhouse should send the next private status nudge.")
            }
        }
        omittedProcess.waitUntilExit()
        let omittedOutput = omittedStdout.drainedText()
        let omittedError = omittedStderr.drainedText()
        XCTAssertEqual(omittedProcess.terminationStatus, 0, "The no-outcome fixture conversation should finish successfully: \(omittedOutput) \(omittedError)")

        let finished = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(finished["status"] as? String, "Blocked", "Unanswered nudges never asked the user anything, so the task is Blocked rather than Waiting Response.")
        XCTAssertTrue((finished["statusMessage"] as? String)?.contains("nudges went unanswered") == true, "The Blocked reason should say the nudges went unanswered.")
        assertTaskVisible("Progress reports", inColumn: "Blocked")
        assertCLIError(try runCLI(["task", "progress", "publish", taskID, "--type", "testing"], expectedStatus: 1), code: "invalid_transition")
        assertCLIError(try runCLI(["task", "outcome", taskID, "completed"], expectedStatus: 1), code: "invalid_transition")
        XCTAssertNil(finished["progressLabel"], "Turn completion should clear the last live report.")
        XCTAssertTrue(waitForDisappearance(report), "Turn completion should remove the progress row from the board card.")
        let reminderHistory = try runCLI(["conversation", "history", taskID])
        let reminderHistoryRecord = try XCTUnwrap(reminderHistory["result"] as? [String: Any])
        let reminderMessages = try XCTUnwrap(reminderHistoryRecord["messages"] as? [[String: Any]])
        XCTAssertTrue(reminderMessages.contains { ($0["text"] as? String)?.contains("Fixture internal reminder reply.") == true }, "Replies to the nudges Playhouse sent stay in the refreshed history.")
        let reminderDiff = try XCTUnwrap(reminderHistoryRecord["diff"] as? [String: Any])
        XCTAssertTrue((reminderDiff["unifiedDiff"] as? String)?.contains("ordinary-turn-diff-after-reminders") == true, "The latest ordinary-turn diff should remain available after private reminders.")
        openTask(named: "Progress reports")
        XCTAssertTrue(transcriptContains("Fixture internal reminder reply."), "Replies to the nudges Playhouse sent appear in the visible transcript.")
        let recoveredProcess = Process()
        recoveredProcess.executableURL = cliURL
        recoveredProcess.arguments = ["conversation", "send", taskID, "--message", "Report the outcome after a reminder."]
        recoveredProcess.environment = environment
        let recoveredStdout = DrainingPipe()
        let recoveredStderr = DrainingPipe()
        recoveredProcess.standardOutput = recoveredStdout.pipe
        recoveredProcess.standardError = recoveredStderr.pipe
        try recoveredProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The reminder recovery fixture turn should become active.")
        try "Release the initial unreported turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The initial unreported turn should finish before the reminder.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "Playhouse should send a private reminder after the omitted outcome.")
        let bridgeEnvironmentURL = URL(fileURLWithPath: executable.path + ".bridge-environment")
        let bridgeEnvironment = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bridgeEnvironmentURL)) as? [String: String]
        )
        let reminderOutcome = try runCLI(["task", "outcome", taskID, "completed"], extraEnvironment: bridgeEnvironment)
        XCTAssertEqual((reminderOutcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
        try "Release the reminder after its outcome is reported.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        recoveredProcess.waitUntilExit()
        let recoveredOutput = recoveredStdout.drainedText()
        let recoveredError = recoveredStderr.drainedText()
        XCTAssertEqual(recoveredProcess.terminationStatus, 0, "The reminder recovery fixture conversation should finish successfully: \(recoveredOutput) \(recoveredError)")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "A completed CLI outcome reported during a private reminder should be honored.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Progress reports", inColumn: "Review")
        openTask(named: "Progress reports")
        XCTAssertTrue(transcriptContains("ended without reporting a task outcome"), "The nudge Playhouse sent must appear in the visible transcript.")
        try assertAutomaticMessageBubble(taskID: taskID, containing: "ended without reporting a task outcome")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse internal outcome nudge:")).count, 0, "The marker line that identifies a nudge is not shown.")
        attachScreenshot(named: "Playhouse status nudge shown as an automatic message")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse private outcome reminder hidden")).count, 0, "Private reminder prompts should not be rendered in the transcript.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse private outcome response hidden")).count, 0, "Private reminder replies should not be rendered in the transcript.")
        let waitingReminderProcess = Process()
        waitingReminderProcess.executableURL = cliURL
        waitingReminderProcess.arguments = ["conversation", "send", taskID, "--message", "Report waiting after a reminder."]
        waitingReminderProcess.environment = environment
        let waitingReminderStdout = DrainingPipe()
        let waitingReminderStderr = DrainingPipe()
        waitingReminderProcess.standardOutput = waitingReminderStdout.pipe
        waitingReminderProcess.standardError = waitingReminderStderr.pipe
        try waitingReminderProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The waiting outcome fixture turn should become active.")
        try "Release the initial unreported turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The initial turn should finish before asking for its outcome.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "Playhouse should send a reminder before reporting a waiting outcome.")
        let waitingReminderOutcome = try runCLI(["task", "outcome", taskID, "waiting-response"], extraEnvironment: bridgeEnvironment)
        XCTAssertEqual((waitingReminderOutcome["result"] as? [String: Any])?["outcome"] as? String, "waiting-response")
        try "Release the reminder after its outcome is reported.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        waitingReminderProcess.waitUntilExit()
        let waitingReminderOutput = waitingReminderStdout.drainedText()
        let waitingReminderError = waitingReminderStderr.drainedText()
        XCTAssertEqual(waitingReminderProcess.terminationStatus, 0, "The waiting reminder fixture conversation should finish successfully: \(waitingReminderOutput) \(waitingReminderError)")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response", "A waiting-response outcome reported during a private reminder should stop retries and be honored.")
        assertTaskVisible("Progress reports", inColumn: "Waiting Response")
        let turnData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let turn = try XCTUnwrap(try JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        let hiddenTurns = try XCTUnwrap(turn["turns"] as? [[String: Any]])
        XCTAssertEqual(hiddenTurns.count, 12, "The omitted outcome should exhaust every nudge; reported outcomes should stop after one nudge.")
        let nudgeTurns = hiddenTurns.filter { ($0["userMessage"] as? String)?.contains("ended without reporting a task outcome") == true }
        XCTAssertEqual(nudgeTurns.count, Self.maxOutcomeContinuations + 2, "Only the missing-outcome sends should receive private status nudges.")
        XCTAssertTrue(nudgeTurns.allSatisfy { ($0["userMessage"] as? String)?.contains("task outcome") == true }, "Each nudge should explicitly direct the agent to report an outcome.")
        XCTAssertTrue(nudgeTurns.allSatisfy { ($0["userMessage"] as? String)?.contains("`in-progress`") == true }, "A nudge must offer in-progress alongside completed and waiting-response.")
        let visibleHistory = try runCLI(["conversation", "history", taskID])
        let visibleMessages = try XCTUnwrap((visibleHistory["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(visibleMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String)?.contains("ended without reporting a task outcome") == true }, "The nudge Playhouse sent must appear in conversation history.")
        let instructions = try XCTUnwrap(turn["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(instructions.contains(cliURL.path))
        XCTAssertTrue(instructions.contains("task progress publish"))
        XCTAssertTrue(instructions.contains("hidden from the conversation"))
        XCTAssertTrue(instructions.contains("at least every 30 seconds"))
        XCTAssertTrue(instructions.contains("starting or finishing a substantial tool call"))
        XCTAssertTrue(instructions.contains("active suite/case and position"))
        XCTAssertTrue(instructions.contains("CLI/XPC 3/8"))
        XCTAssertTrue(instructions.contains("under 80 characters"))
        XCTAssertTrue(instructions.contains("task outcome"))
        XCTAssertTrue(instructions.contains("<completed|in-progress|waiting-response>"))
        XCTAssertTrue(instructions.contains("Never end a turn mid-work without an outcome"))
        XCTAssertTrue(instructions.contains("waiting-response"))
        XCTAssertTrue(instructions.contains("final CLI action"))
        XCTAssertTrue(instructions.contains("before you write your final reply, make exactly one definitive outcome call"))
        XCTAssertTrue(instructions.contains("Write your user-visible final reply after the outcome call returns"))
        XCTAssertTrue(instructions.contains("never end a turn on a tool call"))
        XCTAssertTrue(instructions.contains("previous response had no visible output but you already answered in this turn, do not repeat the answer"))
        XCTAssertEqual(turn["threadStartCount"] as? Int, 1, "The follow-up should reuse the thread created with progress instructions.")
        XCTAssertGreaterThanOrEqual(turn["threadResumeCount"] as? Int ?? 0, 1)
        let turns = try XCTUnwrap(turn["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 12)
        XCTAssertTrue(turns.allSatisfy { $0["developerInstructions"] == nil || $0["developerInstructions"] is NSNull }, "Thread-scoped task instructions should not be repeated in turn requests.")
        let resumeInstructions = try XCTUnwrap(turn["threadResumeDeveloperInstructions"] as? [Any])
        XCTAssertFalse(resumeInstructions.isEmpty, "Resumed task threads should receive updated task instructions.")
        XCTAssertTrue(resumeInstructions.allSatisfy { ($0 as? String)?.contains("task outcome") == true })

        // The bridge daemon starts every provider, including the one a composer turn
        // uses, and must hand it this app's bridge service and store for in-turn outcomes.
        relaunchApp()
        openTask(named: "Progress reports")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The composer should be available for a follow-up.")
        composer.click()
        composer.typeText("Finish this task from the app.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 15), "The composer turn should hold the fixture turn open.")
        let composerBridgeEnvironment = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bridgeEnvironmentURL)) as? [String: String],
            "The provider process should receive the bridge service name and store directory."
        )
        XCTAssertEqual(composerBridgeEnvironment["PLAYHOUSE_BRIDGE_SERVICE_NAME"], serviceName)
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(composerBridgeEnvironment["PLAYHOUSE_DATA_DIRECTORY"])).resolvingSymlinksInPath().path,
            dataDirectory.resolvingSymlinksInPath().path
        )
        let appOutcome = try runCLI(["task", "outcome", taskID, "completed"], extraEnvironment: composerBridgeEnvironment)
        XCTAssertEqual((appOutcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
        try "Release the composer turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 15), "An outcome reported with the provider's inherited environment should move the app-started turn to Review.")
        openTask(named: "Progress reports")
        // The reopened window starts at the newest question, so earlier nudges sit above it: check the history that feeds it.
        let laterNudgeHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertTrue((laterNudgeHistory["messages"] as? [[String: Any]] ?? []).contains {
            ($0["role"] as? String) == "user" && (($0["text"] as? String) ?? "").contains("ended without reporting a task outcome")
        }, "A later composer history refresh must keep earlier nudges shown.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse private outcome reminder hidden")).count, 0, "Earlier private reminders should stay absent after a normal composer turn.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse private outcome response hidden")).count, 0, "Earlier private reminder replies should stay absent after a normal composer turn.")

        // A model can write its outcome command as answer text instead of running
        // it. The echo is hidden, and it counts only when it names this task.
        // Scoped to message containers: a reply's paragraphs are labelled groups too.
        for (turnIndex, (echoedTaskID, expectedColumn)) in [(UUID().uuidString, "Blocked"), (taskID, "Review")].enumerated() {
            let beforeTurnHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            let previousAnswerIDs = Set((beforeTurnHistory["messages"] as? [[String: Any]] ?? []).compactMap { message -> String? in
                guard message["role"] as? String == "assistant",
                      message["text"] as? String == "Fixture answer with an echoed outcome."
                else { return nil }
                return message["id"] as? String
            })
            XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The composer should accept the echoed-outcome turn.")
            composer.click()
            composer.typeText("Echo the outcome command for \(echoedTaskID).")
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 15), "The echoed-outcome turn should hold the fixture turn open.")
            let heldTurns = turnIndex == 0 ? Self.maxOutcomeContinuations + 1 : 1
            for heldTurnIndex in 0..<heldTurns {
                try "Release echoed turn \(heldTurnIndex + 1).\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                if heldTurnIndex < heldTurns - 1 {
                    XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The current echoed turn should finish before a private nudge.")
                    XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "Playhouse should send a private nudge for an unreported echoed outcome.")
                }
            }
            XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == expectedColumn }, timeout: 15), "An echoed outcome for \(echoedTaskID) should leave the task in \(expectedColumn).")
            let turnHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            let turnMessages = try XCTUnwrap(turnHistory["messages"] as? [[String: Any]])
            let visibleAnswer = try XCTUnwrap(turnMessages.last {
                $0["role"] as? String == "assistant"
                    && $0["text"] as? String == "Fixture answer with an echoed outcome."
                    && !previousAnswerIDs.contains($0["id"] as? String ?? "")
            }, "This turn should add its own saved answer without the echoed command.")
            let answerBubble = element("assistant-message-\(try XCTUnwrap(visibleAnswer["id"] as? String))")
            XCTAssertTrue(answerBubble.waitToExist(timeout: 10), "The transcript should show this turn's own answer, not a prior matching reply.")
            XCTAssertTrue(answerBubble.label.contains("Fixture answer with an echoed outcome."))
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "task outcome")).count, 0, "The transcript must not show the echoed outcome command.")
        }
        relaunchApp()
        assertTaskVisible("Progress reports", inColumn: "Review")
    }
    // case-contract: test_task_outcome_in_progress_drives_continuations_until_blocked | An in-progress outcome is accepted during an active turn, leaves the task In Progress, and makes Playhouse send a private continuation turn that names the in-progress report; a completed report during that continuation stops the loop at Review. When every turn reports in-progress, Playhouse sends exactly five continuation turns, keeps the task In Progress throughout, and then marks it Blocked with a continuation-limit reason instead of Waiting Response, since the user was never asked anything. Continuation prompts and replies appear in the conversation history as Playhouse-sent messages and their replies. The user taking the work back ends Playhouse's private driving: stopping a continuation keeps the Stop's Waiting Response with no failure reason, and a queued follow-up runs next instead of being buried under further continuations.
    func test_task_outcome_in_progress_drives_continuations_until_blocked() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-in-progress-continuation-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        // The app reads each opened conversation through this fixture.
        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Continue in progress", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Continue in progress")
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        environment["CODEX_HOME"] = dataDirectory.appendingPathComponent("codex-home").path
        environment["PLAYHOUSE_WORKTREE_LABEL"] = "Playhouse UI Test Worktree"
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = executable.path

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["conversation", "send", taskID, "--message", "Work on this task."]
        process.environment = environment
        let stdout = DrainingPipe()
        let stderr = DrainingPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        try process.run()
        defer {
            if process.isRunning {
                try? "Release the turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 15), "The fixture should hold the first turn open.")
        let reported = try XCTUnwrap(try runCLI(["task", "outcome", taskID, "in-progress"])["result"] as? [String: Any])
        XCTAssertEqual(reported["outcome"] as? String, "in-progress")
        XCTAssertEqual(reported["taskStatus"] as? String, "In Progress", "The outcome is staged until the turn completes.")
        try "Release the in-progress turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 15), "The in-progress turn should finish before its continuation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 15), "Playhouse should send a continuation turn after an in-progress report.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "The task stays In Progress while Playhouse drives the continuation.")
        assertTaskVisible("Continue in progress", inColumn: "In Progress")
        XCTAssertEqual((try runCLI(["task", "outcome", taskID, "completed"])["result"] as? [String: Any])?["outcome"] as? String, "completed")
        try "Release the continuation turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        process.waitUntilExit()
        let output = stdout.drainedText()
        let errorOutput = stderr.drainedText()
        XCTAssertEqual(process.terminationStatus, 0, "The continuation conversation should finish successfully: \(output) \(errorOutput)")
        assertTaskVisible("Continue in progress", inColumn: "Review")
        let continuationHistory = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        )
        let continuationTurns = try XCTUnwrap(continuationHistory["turns"] as? [[String: Any]])
            .filter { ($0["userMessage"] as? String)?.contains("You reported `in-progress`") == true }
        XCTAssertEqual(continuationTurns.count, 1, "One in-progress report earns exactly one continuation turn.")
        XCTAssertTrue(
            (continuationTurns[0]["userMessage"] as? String)?.contains("of \(Self.maxOutcomeContinuations)") == true,
            "The continuation prompt should name the remaining budget."
        )
        openTask(named: "Continue in progress")
        XCTAssertTrue(transcriptContains("You reported"), "Continuation prompts Playhouse sent must appear in the visible transcript.")
        try assertAutomaticMessageBubble(taskID: taskID, containing: "You reported")
        attachScreenshot(named: "Playhouse continuation prompt shown as an automatic message")
        for hidden in ["Playhouse private outcome reminder hidden", "Playhouse private outcome response hidden"] {
            XCTAssertEqual(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", hidden)).count, 0,
                "No placeholder replaces a continuation or its reply."
            )
        }
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))

        // Every turn reports in-progress, so Playhouse runs out of continuations.
        try createTaskFixture(title: "Never settles", roots: [fixture.primary.path])
        let cappedID = try self.taskID(named: "Never settles")
        let cappedExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-in-progress-cap-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cappedExecutable.path))
        codexFixtureExecutable = cappedExecutable.path
        let cappedActive = URL(fileURLWithPath: cappedExecutable.path + ".turn-active")
        let cappedRelease = URL(fileURLWithPath: cappedExecutable.path + ".turn-release")
        try? FileManager.default.removeItem(at: cappedActive)
        try? FileManager.default.removeItem(at: cappedRelease)
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = cappedExecutable.path
        let cappedProcess = Process()
        cappedProcess.executableURL = cliURL
        cappedProcess.arguments = ["conversation", "send", cappedID, "--message", "Work on this task."]
        cappedProcess.environment = environment
        let cappedStdout = DrainingPipe()
        let cappedStderr = DrainingPipe()
        cappedProcess.standardOutput = cappedStdout.pipe
        cappedProcess.standardError = cappedStderr.pipe
        try cappedProcess.run()
        defer {
            if cappedProcess.isRunning {
                try? "Release the capped turn.\n".write(to: cappedRelease, atomically: true, encoding: .utf8)
                cappedProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: cappedActive)
            try? FileManager.default.removeItem(at: cappedRelease)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: cappedActive.path) }, timeout: 15), "The capped fixture should hold its first turn open.")
        for index in 0...Self.maxOutcomeContinuations {
            XCTAssertEqual(
                try taskRecord(id: cappedID)?["status"] as? String, "In Progress",
                "Every continuation keeps the task In Progress until the limit is reached."
            )
            XCTAssertEqual(
                (try runCLI(["task", "outcome", cappedID, "in-progress"])["result"] as? [String: Any])?["outcome"] as? String,
                "in-progress"
            )
            try "Release turn \(index + 1).\n".write(to: cappedRelease, atomically: true, encoding: .utf8)
            if index < Self.maxOutcomeContinuations {
                XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: cappedActive.path) }, timeout: 15), "The fixture should finish the current continuation turn.")
                XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: cappedActive.path) }, timeout: 15), "Playhouse should send the next continuation turn.")
            }
        }
        cappedProcess.waitUntilExit()
        let cappedOutput = cappedStdout.drainedText()
        let cappedError = cappedStderr.drainedText()
        XCTAssertEqual(cappedProcess.terminationStatus, 0, "The capped continuation conversation should finish successfully: \(cappedOutput) \(cappedError)")
        let cappedRecord = try XCTUnwrap(taskRecord(id: cappedID))
        XCTAssertEqual(cappedRecord["status"] as? String, "Blocked", "Running out of continuations is Blocked, not Waiting Response.")
        XCTAssertTrue(
            (cappedRecord["statusMessage"] as? String)?.contains("continuation turns") == true,
            "The Blocked reason should name the continuation limit."
        )
        assertTaskVisible("Never settles", inColumn: "Blocked")
        let cappedHistory = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cappedExecutable.path + ".history"))) as? [String: Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(cappedHistory["turns"] as? [[String: Any]])
                .filter { ($0["userMessage"] as? String)?.contains("You reported `in-progress`") == true }.count,
            Self.maxOutcomeContinuations,
            "Playhouse stops driving the work after the continuation limit."
        )

        // Stopping a private continuation is the user taking the work back.
        try createTaskFixture(title: "Stopped mid continuation", roots: [fixture.primary.path])
        let stopID = try self.taskID(named: "Stopped mid continuation")
        let stopExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-in-progress-stop-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: stopExecutable.path))
        codexFixtureExecutable = stopExecutable.path
        let stopActive = URL(fileURLWithPath: stopExecutable.path + ".turn-active")
        let stopRelease = URL(fileURLWithPath: stopExecutable.path + ".turn-release")
        try? FileManager.default.removeItem(at: stopActive)
        try? FileManager.default.removeItem(at: stopRelease)
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = stopExecutable.path
        let stopProcess = Process()
        stopProcess.executableURL = cliURL
        stopProcess.arguments = ["conversation", "send", stopID, "--message", "Work on this task."]
        stopProcess.environment = environment
        stopProcess.standardOutput = DrainingPipe().pipe
        stopProcess.standardError = DrainingPipe().pipe
        try stopProcess.run()
        defer {
            if stopProcess.isRunning {
                try? "Release the stopped continuation.\n".write(to: stopRelease, atomically: true, encoding: .utf8)
                stopProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: stopActive)
            try? FileManager.default.removeItem(at: stopRelease)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: stopActive.path) }, timeout: 15), "The stop fixture should hold its first turn open.")
        XCTAssertEqual((try runCLI(["task", "outcome", stopID, "in-progress"])["result"] as? [String: Any])?["outcome"] as? String, "in-progress")
        try "Release the in-progress turn.\n".write(to: stopRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: stopActive.path) }, timeout: 15), "The in-progress turn should finish before its continuation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: stopActive.path) }, timeout: 15), "Playhouse should send a continuation turn before the Stop.")
        // Stop persists the paused state before the provider answers, and the
        // held fixture turn only replies once released, so the Stop has to run
        // alongside the release rather than before it.
        let stopper = try startCLIProcess(["conversation", "stop", stopID])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: stopID)?["status"] as? String) == "Waiting Response" }, timeout: 20),
                      "Stop should persist the paused state before the provider acknowledges it.")
        try "Release the stopped continuation.\n".write(to: stopRelease, atomically: true, encoding: .utf8)
        _ = try finishCLIProcess(stopper)
        stopProcess.waitUntilExit()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: stopID)?["status"] as? String) == "Waiting Response" }, timeout: 30),
                      "A Stop during a continuation keeps the user's paused state.")
        XCTAssertNil(try taskRecord(id: stopID)?["statusMessage"] as? String,
                     "A user-requested Stop must not be reported as a Playhouse failure.")
        assertTaskVisible("Stopped mid continuation", inColumn: "Waiting Response")
        let stopHistory = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: stopExecutable.path + ".history"))) as? [String: Any]
        )
        XCTAssertEqual(
            try XCTUnwrap(stopHistory["turns"] as? [[String: Any]])
                .filter { ($0["userMessage"] as? String)?.contains("You reported `in-progress`") == true }.count,
            1,
            "Playhouse must stop driving the work once the user stops it."
        )

        // A queued follow-up is the other way the user takes over.
        try createTaskFixture(title: "Queued over continuation", roots: [fixture.primary.path])
        let queuedID = try self.taskID(named: "Queued over continuation")
        let queuedExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-in-progress-queue-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: queuedExecutable.path))
        codexFixtureExecutable = queuedExecutable.path
        let queuedActive = URL(fileURLWithPath: queuedExecutable.path + ".turn-active")
        let queuedRelease = URL(fileURLWithPath: queuedExecutable.path + ".turn-release")
        try? FileManager.default.removeItem(at: queuedActive)
        try? FileManager.default.removeItem(at: queuedRelease)
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = queuedExecutable.path
        let queuedProcess = Process()
        queuedProcess.executableURL = cliURL
        queuedProcess.arguments = ["conversation", "send", queuedID, "--message", "Work on this task."]
        queuedProcess.environment = environment
        queuedProcess.standardOutput = DrainingPipe().pipe
        queuedProcess.standardError = DrainingPipe().pipe
        try queuedProcess.run()
        defer {
            if queuedProcess.isRunning {
                try? "Release the next turn.\n".write(to: queuedRelease, atomically: true, encoding: .utf8)
                queuedProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: queuedActive)
            try? FileManager.default.removeItem(at: queuedRelease)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: queuedActive.path) }, timeout: 15), "The queue fixture should hold its first turn open.")
        XCTAssertEqual((try runCLI(["task", "outcome", queuedID, "in-progress"])["result"] as? [String: Any])?["outcome"] as? String, "in-progress")
        _ = try runCLI(["conversation", "queue", queuedID, "--message", "Follow-up from the user."])
        XCTAssertTrue(waitUntil({
            try? "Release the next turn.\n".write(to: queuedRelease, atomically: true, encoding: .utf8)
            return !queuedProcess.isRunning
        }, timeout: 60), "The queued follow-up should run instead of further continuations.")
        queuedProcess.waitUntilExit()
        // The follow-up turn settles on its own terms; what matters here is that
        // it ran next instead of queueing behind Playhouse's continuations.
        let queuedHistory = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: queuedExecutable.path + ".history"))) as? [String: Any]
        )
        let queuedTurns = try XCTUnwrap(queuedHistory["turns"] as? [[String: Any]])
        XCTAssertEqual(
            queuedTurns.filter { ($0["userMessage"] as? String)?.contains("You reported `in-progress`") == true }.count, 0,
            "A queued follow-up must take precedence over Playhouse's private continuation."
        )
        XCTAssertTrue(
            queuedTurns.contains { ($0["userMessage"] as? String)?.contains("Follow-up from the user.") == true },
            "The queued follow-up should be the next turn the provider receives."
        )
        // This task's thread lives in the queue fixture; the app must read it there.
        relaunchApp()
        openTask(named: "Queued over continuation")
        XCTAssertTrue(transcriptMessage("Follow-up from the user.").waitToExist(timeout: 15),
                      "The queued follow-up should be visible in the conversation it ran in.")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "You reported")).count, 0,
            "No private continuation prompt should be visible ahead of the user's follow-up."
        )
    }
}

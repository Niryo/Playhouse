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
    // case-contract: test_waiting_response_task_moves_to_review_manually | A task in Waiting Response moves to Review through the CLI and on the board, both from its card's Move to Review context-menu item, which Waiting Response and Blocked cards offer, and by dragging the card onto the Review column. The move runs the same review gate as a completed outcome: local changes on a PR-linked worktree are committed before the task reaches Review. It clears the waiting status, persists across a fresh CLI/XPC read, keeps the linked pull request, returns a task already in Review unchanged, and the moved task can still complete to Done. A Backlog task is rejected and keeps its status; a task whose turn is still running while it shows Waiting Response is rejected and keeps both its status and its uncommitted changes; and when the pull request sync fails, the move reports the error, shown on the board as an alert, and leaves the task in Waiting Response; once GitHub reports the pull request merged, a retry commits local work, skips syncing the merged branch even though its remote is unreachable, and moves the task to Review. Each transition into Waiting Response plays Ping and each transition into Review plays Glass; rejected and repeated moves play no sound.
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
        XCTAssertFalse(element("move-task-to-review-menu-item").exists, "A Backlog card offers no Move to Review.")
        app.typeKey(.escape, modifierFlags: [])

        // A pending blocking question shows Waiting Response while its turn still runs.
        openTask(named: "Manual review menu")
        setPlanMode(true)
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

    // case-contract: test_waiting_and_blocked_tasks_move_directly_to_review_and_done | A task in Waiting Response moves straight to Done, and a Blocked task moves to Review or straight to Done, through the CLI and on the board: Waiting Response and Blocked cards offer Move to Done in their context menu, Blocked cards also offer Move to Review, a Blocked card dragged onto the Review column lands in Review, and a Blocked card dragged onto the Done drawer lands in Done; a Backlog card offers neither and a Backlog task is still rejected for both moves and keeps its status. Moving a Waiting Response task to Done while its blocking question's turn still runs is rejected as still running, shown on the board in a Couldn't move task to Done alert, and keeps the task in Waiting Response with its worktree in place; once the turn finishes, Move to Done reaches Done and removes the task's clean Playhouse worktree as a move from Review does. Moving a Blocked task to Review clears its blocked reason and plays Glass; moving one to Done clears it too. Each move persists across a fresh CLI/XPC read, and a task already in Done is returned unchanged.
    func test_waiting_and_blocked_tasks_move_directly_to_review_and_done() throws {
        let questionFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-status-transition-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: questionFixture.path))
        codexFixtureExecutable = questionFixture.path
        let emptyFixture = try makeCodexFixture(emptyQuestions: true)
        launchApp(defaultParent: fixture.parent.path)

        func blockedTask(_ title: String) throws -> String {
            let created = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.secondary.path])
            let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
            assertCLIError(
                try runCLI(
                    ["conversation", "send", id, "--message", "Please ask your questions."],
                    expectedStatus: 1,
                    extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": emptyFixture.path]
                ),
                code: "operation_failed"
            )
            XCTAssertEqual(try taskRecord(id: id)?["status"] as? String, "Blocked")
            XCTAssertNotNil(try taskRecord(id: id)?["statusMessage"] as? String, "A blocked task carries the reason it is blocked.")
            return id
        }
        func statusSounds(_ id: String) throws -> [String] {
            try diagnosticEvents().filter {
                $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == id
            }.compactMap { $0["sound"] as? String }
        }
        let moveToDone = element("move-task-to-done-menu-item")
        let moveToReview = element("move-task-to-review-menu-item")

        // Backlog still can't skip ahead to Done or Review.
        try createTaskFixture(title: "Direct move backlog", roots: [fixture.alternate.path])
        let backlogTaskID = try taskID(named: "Direct move backlog")
        assertCLIError(try runCLI(["task", "move", backlogTaskID, "Done"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["task", "move", backlogTaskID, "Review"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try taskRecord(id: backlogTaskID)?["status"] as? String, "Backlog")
        element("task-card-\(backlogTaskID)").rightClick()
        XCTAssertTrue(element("rename-task-menu-item").waitToExist(timeout: 5))
        XCTAssertFalse(moveToDone.exists, "A Backlog card offers no Move to Done.")
        XCTAssertFalse(moveToReview.exists, "A Backlog card offers no Move to Review.")
        app.typeKey(.escape, modifierFlags: [])

        // Waiting Response -> Done, refused while the question's turn still runs.
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Direct waiting done", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any])
        let waitingTaskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Direct waiting done")
        setPlanMode(true)
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        let record = try XCTUnwrap((try taskRecord(id: waitingTaskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Direct waiting done", inColumn: "Waiting Response")

        let waitingCard = element("task-card-\(waitingTaskID)")
        let doneRejection = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        waitingCard.rightClick()
        XCTAssertTrue(moveToDone.waitToExist(timeout: 5), "A Waiting Response card should offer Move to Done.")
        XCTAssertTrue(moveToReview.exists, "A Waiting Response card still offers Move to Review.")
        moveToDone.click()
        XCTAssertTrue(doneRejection.waitToExist(timeout: 10), "Moving a task whose turn is still running to Done should explain the rejection.")
        XCTAssertTrue(doneRejection.staticTexts.matching(NSPredicate(format: "value == %@", "Couldn't move task to Done")).firstMatch.exists)
        XCTAssertTrue(doneRejection.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "still running")).firstMatch.exists)
        attachScreenshot(named: "Move to Done is refused while the question's turn still runs")
        doneRejection.buttons["OK"].click()
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path), "A refused move must leave the running turn's worktree in place.")
        assertTaskVisible("Direct waiting done", inColumn: "Waiting Response")

        openTask(named: "Direct waiting done")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 5))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
        let threadID = try XCTUnwrap(try taskRecord(id: waitingTaskID)?["codexThreadID"] as? String)
        XCTAssertTrue(waitUntil({
            let runtime = (try? self.runCLI(["conversation", "runtime"]))?["result"] as? [String: Any]
            return runtime != nil && !((runtime?["activeThreadIDs"] as? [String] ?? []).contains(threadID))
                && (try? self.taskRecord(id: waitingTaskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 30), "The answered turn should finish in Waiting Response.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        waitingCard.rightClick()
        XCTAssertTrue(moveToDone.waitToExist(timeout: 5))
        attachScreenshot(named: "A Waiting Response card offers Move to Done")
        attachElementScreenshot(app.menus.firstMatch, named: "Waiting Response card menu close-up with Move to Done")
        moveToDone.click()
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: waitingTaskID)?["status"] as? String) == "Done"
        }, timeout: 15), "Move to Done should take a Waiting Response task straight to Done.")
        XCTAssertNil(try taskRecord(id: waitingTaskID)?["statusMessage"] as? String)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: worktree.path) }, timeout: 10),
                      "Done removes the task's clean Playhouse worktree as it does from Review.")
        XCTAssertTrue(waitUntil({ !waitingCard.exists }, timeout: 10), "The Done task leaves the board.")
        XCTAssertFalse(doneRejection.exists)

        // Blocked -> Review clears the blocked reason and plays the Review sound.
        let reviewTaskID = try blockedTask("Direct blocked review")
        assertTaskVisible("Direct blocked review", inColumn: "Blocked")
        let blockedSoundCount = try statusSounds(reviewTaskID).count
        element("task-card-\(reviewTaskID)").rightClick()
        XCTAssertTrue(moveToReview.waitToExist(timeout: 5), "A Blocked card should offer Move to Review.")
        XCTAssertTrue(moveToDone.exists, "A Blocked card should offer Move to Done.")
        attachScreenshot(named: "A Blocked card offers Move to Review and Move to Done")
        attachElementScreenshot(app.menus.firstMatch, named: "Blocked card menu close-up with Move to Review and Move to Done")
        moveToReview.click()
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: reviewTaskID)?["status"] as? String) == "Review"
        }, timeout: 15), "Move to Review should take a Blocked task to Review.")
        XCTAssertNil(try taskRecord(id: reviewTaskID)?["statusMessage"] as? String)
        assertTaskVisible("Direct blocked review", inColumn: "Review")
        XCTAssertEqual(Array(try statusSounds(reviewTaskID).dropFirst(blockedSoundCount)), ["Glass"])

        // Blocked -> Review by dragging the card onto the Review column.
        let dragReviewTaskID = try blockedTask("Direct blocked review drag")
        assertTaskVisible("Direct blocked review drag", inColumn: "Blocked")
        let reviewColumn = element("column-review")
        XCTAssertTrue(reviewColumn.waitToExist(timeout: 5))
        XCTAssertTrue(waitForStableFrame(element("task-card-\(dragReviewTaskID)")), "The card should settle in Blocked before the drag.")
        element("task-card-\(dragReviewTaskID)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: reviewColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: dragReviewTaskID)?["status"] as? String) == "Review"
        }, timeout: 15), "Dropping a Blocked card on Review should persist the Review status.")
        XCTAssertNil(try taskRecord(id: dragReviewTaskID)?["statusMessage"] as? String)
        assertDoneDrawerResting("after a Blocked card is dropped on Review")
        assertTaskVisible("Direct blocked review drag", inColumn: "Review")

        // Blocked -> Done by dragging the card onto the Done drawer.
        let doneTaskID = try blockedTask("Direct blocked done")
        assertTaskVisible("Direct blocked done", inColumn: "Blocked")
        XCTAssertTrue(waitForStableFrame(element("task-card-\(doneTaskID)")), "The card should settle in Blocked before the drag.")
        moveTaskToDone(taskID: doneTaskID)
        XCTAssertNil(try taskRecord(id: doneTaskID)?["statusMessage"] as? String)
        assertDoneDrawerResting("after a Blocked card is dropped on Done")
        XCTAssertFalse(element("column-heading-blocked").exists, "Blocked hides once its tasks moved on.")
        XCTAssertEqual(
            (try runCLI(["task", "move", doneTaskID, "Done"])["result"] as? [String: Any])?["status"] as? String,
            "Done",
            "A task already in Done is returned unchanged."
        )
        assertTaskVisible("Direct blocked review", inColumn: "Review")
        attachScreenshot(named: "Blocked and Waiting Response tasks moved on directly")
        XCTAssertEqual(try taskRecord(id: backlogTaskID)?["status"] as? String, "Backlog")
    }
    // case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; provider processes started from the CLI/XPC service or the app's composer inherit that app's bridge service name and store directory, and an outcome reported with exactly that inherited environment reaches the task. A successful turn without an outcome and with nothing left running receives exactly one private recovery prompt that offers only the stopping outcomes; a completed report during it moves the task to Review, a waiting-response report during it leaves the task in Waiting Response, and no report by its end marks the task Blocked with the missing-outcome reason rather than Waiting Response, since the user was never asked anything. The board shows progress details and places completed tasks in Review and waiting outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work; they offer no outcome for unfinished work and tell the agent to keep awaiting a required command within the turn. They place the outcome call, still the final CLI action, before the user-visible final reply, which ends the turn so it never ends on a tool call, and they tell the agent not to repeat an answer after a no-visible-output notice. Only an explicit completed outcome reaches Review. When a final answer ends with the outcome command written as text instead of run, the final answer, fresh history, and transcript hide that command, and it counts as the turn's outcome only when it names this task. A recovery prompt Playhouse sent shows its prompt and the agent's reply in history and the visible transcript, including after later ordinary turns. Fresh history after those prompts also retains the latest ordinary-turn diff while showing their replies. Completed and waiting-response outcomes start Glass and Ping respectively when their turns settle.
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
        for nudgeIndex in 0...Self.outcomeRecoveryPrompts {
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "The fallback status should be deferred until the recovery prompt finishes.")
            try "Release turn \(nudgeIndex + 1).\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
            if nudgeIndex < Self.outcomeRecoveryPrompts {
                XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The fixture should finish the current unreported turn.")
                XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "Playhouse should send its one private recovery prompt.")
            }
        }
        omittedProcess.waitUntilExit()
        let omittedOutput = omittedStdout.drainedText()
        let omittedError = omittedStderr.drainedText()
        XCTAssertEqual(omittedProcess.terminationStatus, 0, "The no-outcome fixture conversation should finish successfully: \(omittedOutput) \(omittedError)")

        let finished = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(finished["status"] as? String, "Blocked", "An unanswered recovery prompt never asked the user anything, so the task is Blocked rather than Waiting Response.")
        XCTAssertTrue((finished["statusMessage"] as? String)?.contains("one recovery prompt went unanswered") == true, "The Blocked reason should say the recovery prompt went unanswered.")
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
        // Restart the provider so the next send resumes the existing thread on a fresh
        // app-server, which must hand the thread updated task instructions.
        try restartProvider(executable)
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
        XCTAssertEqual(hiddenTurns.count, 8, "Each missing-outcome send earns exactly one recovery prompt.")
        let nudgeTurns = hiddenTurns.filter { ($0["userMessage"] as? String)?.contains("ended without reporting a task outcome") == true }
        XCTAssertEqual(nudgeTurns.count, Self.outcomeRecoveryPrompts + 2, "Each missing-outcome send should receive exactly one private recovery prompt.")
        XCTAssertTrue(nudgeTurns.allSatisfy { ($0["userMessage"] as? String)?.contains("task outcome") == true }, "Each nudge should explicitly direct the agent to report an outcome.")
        XCTAssertTrue(nudgeTurns.allSatisfy { ($0["userMessage"] as? String)?.contains("in-progress") == false && ($0["userMessage"] as? String)?.contains("blocked --reason") == true && ($0["userMessage"] as? String)?.contains("This is the only recovery prompt") == true }, "The recovery prompt offers only stopping outcomes.")
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
        XCTAssertTrue(instructions.contains("<completed|waiting-response|blocked>"))
        XCTAssertTrue(instructions.contains("There is no outcome for unfinished work"))
        XCTAssertTrue(instructions.contains("keep awaiting or polling that same command session in this turn"))
        XCTAssertFalse(instructions.contains("in-progress"))
        XCTAssertTrue(instructions.contains("sends one private recovery prompt"))
        XCTAssertTrue(instructions.contains("waiting-response"))
        XCTAssertTrue(instructions.contains("final CLI action"))
        XCTAssertTrue(instructions.contains("before you write your final reply, make exactly one stopping outcome call"))
        XCTAssertTrue(instructions.contains("Write your user-visible final reply after the outcome call returns"))
        XCTAssertTrue(instructions.contains("never end a turn on a tool call"))
        XCTAssertTrue(instructions.contains("previous response had no visible output but you already answered in this turn, do not repeat the answer"))
        XCTAssertEqual(turn["threadStartCount"] as? Int, 1, "The follow-up should reuse the thread created with progress instructions.")
        // The window and the CLI sends each run their own app-server, and each new one
        // resumes the thread, so the count depends on that topology; history reads don't.
        XCTAssertGreaterThanOrEqual(turn["threadResumeCount"] as? Int ?? 0, 1, "The restarted provider resumes the thread.")
        let requestedMethods = try String(contentsOfFile: executable.path + ".methods", encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(requestedMethods.contains("turn/start"), "The method log saw this case's turns.")
        for method in ["thread/read", "thread/turns/list", "thread/items/list"] {
            XCTAssertFalse(requestedMethods.contains(method), "History is read from Playhouse's store, never from Codex's thread.")
        }
        let turns = try XCTUnwrap(turn["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 8)
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
            let heldTurns = turnIndex == 0 ? Self.outcomeRecoveryPrompts + 1 : 1
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
    // case-contract: test_task_stopping_outcomes_and_single_recovery_prompt | A turn has three stopping outcomes and none for unfinished work. A blocked report needs a reason and settles the task in Blocked with that reason; a blocked report without one, or with one longer than 500 characters, is rejected, as is a reason on any other outcome; a legacy in-progress report is answered with guidance, records nothing, withdraws an outcome staged earlier in the turn, and leaves the task In Progress. A turn that ends with no stopping outcome and nothing running gets exactly one private recovery prompt, during which the task stays In Progress; a completed report in that turn settles the task in Review, and a recovery turn that also ends unsettled leaves the task Blocked with a missing-outcome reason and no further prompts. The recovery prompt and its reply appear in the conversation history as a Playhouse-sent message and its reply. The user taking the work back ends Playhouse's private driving: stopping the recovery turn keeps the Stop's Waiting Response with no failure reason, and a queued follow-up runs next instead of a recovery prompt.
    func test_task_stopping_outcomes_and_single_recovery_prompt() throws {
        let recoveryMarker = "ended without reporting a task outcome"
        func fixtureExecutable(_ name: String) -> URL {
            let executable = WorkspaceFixture.root.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "\(name) should be installed.")
            return executable
        }
        func fixtureTurns(_ executable: URL) throws -> [[String: Any]] {
            let history = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
            )
            return try XCTUnwrap(history["turns"] as? [[String: Any]])
        }
        func recoveryTurns(_ executable: URL) throws -> [[String: Any]] {
            try fixtureTurns(executable).filter { ($0["userMessage"] as? String)?.contains(recoveryMarker) == true }
        }
        func exists(_ marker: URL) -> Bool { FileManager.default.fileExists(atPath: marker.path) }
        func release(_ marker: URL, _ text: String) { try? (text + "\n").write(to: marker, atomically: true, encoding: .utf8) }

        let executable = fixtureExecutable("codex-fixture-outcome-recovery-hold-release")
        // The app reads each opened conversation through this fixture.
        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Recovers once", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Recovers once")
        let turn = try startProgressFixtureTurn(taskID: taskID, executable: executable)
        defer {
            if turn.process.isRunning {
                release(turn.releaseMarker, "Release the turn.")
                turn.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ exists(turn.activeMarker) }, timeout: 15), "The fixture should hold the first turn open.")
        // A legacy in-progress report withdraws an outcome staged earlier in the turn: the
        // recovery prompt below is only sent because nothing is left staged.
        let staged = try XCTUnwrap(try runCLI(["task", "outcome", taskID, "waiting-response"])["result"] as? [String: Any])
        XCTAssertEqual(staged["recorded"] as? Bool, true)
        let legacy = try XCTUnwrap(try runCLI(["task", "outcome", taskID, "in-progress"])["result"] as? [String: Any])
        XCTAssertEqual(legacy["recorded"] as? Bool, false, "in-progress is no longer an outcome, so nothing is staged for it.")
        XCTAssertEqual(legacy["taskStatus"] as? String, "In Progress")
        XCTAssertTrue((legacy["message"] as? String)?.contains("no longer a turn outcome") == true)
        XCTAssertTrue((legacy["message"] as? String)?.contains("blocked --reason") == true)
        let unexplained = try runCLI(["task", "outcome", taskID, "blocked"], expectedStatus: 2)
        XCTAssertTrue(((unexplained["error"] as? [String: Any])?["message"] as? String)?.contains("--reason") == true)
        let overlong = try runCLI(["task", "outcome", taskID, "blocked", "--reason", String(repeating: "x", count: 501)], expectedStatus: 2)
        XCTAssertTrue(((overlong["error"] as? [String: Any])?["message"] as? String)?.contains("1 to 500 characters") == true)
        let misplaced = try runCLI(["task", "outcome", taskID, "completed", "--reason", "Not a blocker."], expectedStatus: 2)
        XCTAssertTrue(((misplaced["error"] as? [String: Any])?["message"] as? String)?.contains("Only a blocked outcome takes --reason") == true)
        release(turn.releaseMarker, "Release the unsettled turn.")
        XCTAssertTrue(waitUntil({ !exists(turn.activeMarker) }, timeout: 15), "The first turn should end without a stopping outcome.")
        XCTAssertTrue(waitUntil({ exists(turn.activeMarker) }, timeout: 15), "Playhouse should send one recovery prompt for a turn that ended unsettled.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "The task stays In Progress while the recovery turn is running.")
        assertTaskVisible("Recovers once", inColumn: "In Progress")
        attachScreenshot(named: "Task stays In Progress while its recovery turn runs")
        let completed = try XCTUnwrap(try runCLI(["task", "outcome", taskID, "completed"])["result"] as? [String: Any])
        XCTAssertEqual(completed["outcome"] as? String, "completed")
        XCTAssertEqual(completed["recorded"] as? Bool, true)
        XCTAssertEqual(completed["taskStatus"] as? String, "In Progress", "The outcome is staged until the turn completes.")
        release(turn.releaseMarker, "Release the recovery turn.")
        turn.process.waitUntilExit()
        XCTAssertEqual(turn.process.terminationStatus, 0, "The recovery conversation should finish successfully.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "A completed report during the recovery turn settles the task in Review.")
        assertTaskVisible("Recovers once", inColumn: "Review")
        XCTAssertEqual(try recoveryTurns(executable).count, 1, "An unsettled turn earns exactly one recovery prompt.")
        XCTAssertTrue((try recoveryTurns(executable)[0]["userMessage"] as? String)?.contains("This is the only recovery prompt") == true)

        try createTaskFixture(title: "Blocked with a reason", roots: [fixture.primary.path])
        let blockedID = try self.taskID(named: "Blocked with a reason")
        let blockedExecutable = fixtureExecutable("codex-fixture-outcome-blocked-hold-release")
        codexFixtureExecutable = blockedExecutable.path
        let blocked = try startProgressFixtureTurn(taskID: blockedID, executable: blockedExecutable)
        defer {
            if blocked.process.isRunning {
                release(blocked.releaseMarker, "Release the blocked turn.")
                blocked.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ exists(blocked.activeMarker) }, timeout: 15), "The blocked fixture should hold its turn open.")
        let reported = try XCTUnwrap(
            try runCLI(["task", "outcome", blockedID, "blocked", "--reason", "The signing certificate expired."])["result"] as? [String: Any]
        )
        XCTAssertEqual(reported["outcome"] as? String, "blocked")
        XCTAssertEqual(reported["taskStatus"] as? String, "In Progress", "A blocked outcome is staged until the turn completes.")
        release(blocked.releaseMarker, "Release the blocked turn.")
        blocked.process.waitUntilExit()
        XCTAssertEqual(blocked.process.terminationStatus, 0, "The blocked conversation should finish successfully.")
        let blockedRecord = try XCTUnwrap(taskRecord(id: blockedID))
        XCTAssertEqual(blockedRecord["status"] as? String, "Blocked")
        XCTAssertEqual(blockedRecord["statusMessage"] as? String, "The signing certificate expired.")
        XCTAssertEqual(try recoveryTurns(blockedExecutable).count, 0, "A reported stopping outcome needs no recovery prompt.")
        assertTaskVisible("Blocked with a reason", inColumn: "Blocked")
        let blockedCardMessage = element("task-status-message-\(blockedID)")
        XCTAssertTrue(blockedCardMessage.waitToExist(timeout: 10), "The Blocked card should show the agent's reason.")
        XCTAssertTrue(accessibleLabelOrValue(of: blockedCardMessage).contains("The signing certificate expired."))
        attachScreenshot(named: "Blocked card shows the reason the agent reported")

        try createTaskFixture(title: "Never settles", roots: [fixture.primary.path])
        let unansweredID = try self.taskID(named: "Never settles")
        let unansweredExecutable = fixtureExecutable("codex-fixture-outcome-unanswered-hold-release")
        codexFixtureExecutable = unansweredExecutable.path
        let unanswered = try startProgressFixtureTurn(taskID: unansweredID, executable: unansweredExecutable)
        defer {
            if unanswered.process.isRunning {
                release(unanswered.releaseMarker, "Release the recovery turn.")
                unanswered.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ exists(unanswered.activeMarker) }, timeout: 15), "The unanswered fixture should hold its first turn open.")
        release(unanswered.releaseMarker, "Release the unsettled turn.")
        XCTAssertTrue(waitUntil({ !exists(unanswered.activeMarker) }, timeout: 15), "The first turn should end without a stopping outcome.")
        XCTAssertTrue(waitUntil({ exists(unanswered.activeMarker) }, timeout: 15), "Playhouse should send its one recovery prompt.")
        XCTAssertEqual(try taskRecord(id: unansweredID)?["status"] as? String, "In Progress", "A recovery turn that is running keeps the task In Progress.")
        release(unanswered.releaseMarker, "Release the recovery turn.")
        unanswered.process.waitUntilExit()
        XCTAssertEqual(unanswered.process.terminationStatus, 0, "The unanswered recovery conversation should finish successfully.")
        let unansweredRecord = try XCTUnwrap(taskRecord(id: unansweredID))
        XCTAssertEqual(unansweredRecord["status"] as? String, "Blocked", "An unanswered recovery prompt is Blocked, not Waiting Response.")
        XCTAssertTrue((unansweredRecord["statusMessage"] as? String)?.contains("one recovery prompt went unanswered") == true)
        XCTAssertEqual(try recoveryTurns(unansweredExecutable).count, 1, "Playhouse sends no second recovery prompt.")
        assertTaskVisible("Never settles", inColumn: "Blocked")
        let unansweredCardMessage = element("task-status-message-\(unansweredID)")
        XCTAssertTrue(unansweredCardMessage.waitToExist(timeout: 10), "The Blocked card should explain the missing outcome.")
        XCTAssertTrue(accessibleLabelOrValue(of: unansweredCardMessage).contains("one recovery prompt went unanswered"))
        attachScreenshot(named: "Blocked card explains the missing stopping outcome")

        // Stopping the recovery turn is the user taking the work back.
        try createTaskFixture(title: "Stopped mid recovery", roots: [fixture.primary.path])
        let stopID = try self.taskID(named: "Stopped mid recovery")
        let stopExecutable = fixtureExecutable("codex-fixture-outcome-stop-hold-release")
        codexFixtureExecutable = stopExecutable.path
        let stopped = try startProgressFixtureTurn(taskID: stopID, executable: stopExecutable)
        defer {
            if stopped.process.isRunning {
                release(stopped.releaseMarker, "Release the stopped recovery turn.")
                stopped.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ exists(stopped.activeMarker) }, timeout: 15), "The stop fixture should hold its first turn open.")
        release(stopped.releaseMarker, "Release the unsettled turn.")
        XCTAssertTrue(waitUntil({ !exists(stopped.activeMarker) }, timeout: 15), "The first turn should end without a stopping outcome.")
        XCTAssertTrue(waitUntil({ exists(stopped.activeMarker) }, timeout: 15), "Playhouse should send its recovery prompt before the Stop.")
        // Stop persists the paused state before the provider answers, and the
        // held fixture turn only replies once released, so the Stop has to run
        // alongside the release rather than before it.
        let stopper = try startCLIProcess(["conversation", "stop", stopID])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: stopID)?["status"] as? String) == "Waiting Response" }, timeout: 20),
                      "Stop should persist the paused state before the provider acknowledges it.")
        release(stopped.releaseMarker, "Release the stopped recovery turn.")
        _ = try finishCLIProcess(stopper)
        stopped.process.waitUntilExit()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: stopID)?["status"] as? String) == "Waiting Response" }, timeout: 30),
                      "A Stop during the recovery turn keeps the user's paused state.")
        XCTAssertNil(try taskRecord(id: stopID)?["statusMessage"] as? String,
                     "A user-requested Stop must not be reported as a Playhouse failure.")
        assertTaskVisible("Stopped mid recovery", inColumn: "Waiting Response")
        XCTAssertEqual(try recoveryTurns(stopExecutable).count, 1, "Playhouse must not restart the work once the user stops it.")

        // A queued follow-up is the other way the user takes over.
        try createTaskFixture(title: "Queued over recovery", roots: [fixture.primary.path])
        let queuedID = try self.taskID(named: "Queued over recovery")
        let queuedExecutable = fixtureExecutable("codex-fixture-outcome-queue-hold-release")
        codexFixtureExecutable = queuedExecutable.path
        let queued = try startProgressFixtureTurn(taskID: queuedID, executable: queuedExecutable)
        defer {
            if queued.process.isRunning {
                release(queued.releaseMarker, "Release the next turn.")
                queued.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ exists(queued.activeMarker) }, timeout: 15), "The queue fixture should hold its first turn open.")
        _ = try runCLI(["conversation", "queue", queuedID, "--message", "Follow-up from the user."])
        XCTAssertTrue(waitUntil({
            release(queued.releaseMarker, "Release the next turn.")
            return !queued.process.isRunning
        }, timeout: 60), "The queued follow-up should run instead of a recovery prompt.")
        queued.process.waitUntilExit()
        let queuedTurns = try fixtureTurns(queuedExecutable)
        XCTAssertGreaterThanOrEqual(queuedTurns.count, 2)
        XCTAssertTrue(
            (queuedTurns[1]["userMessage"] as? String)?.contains("Follow-up from the user.") == true,
            "A queued follow-up must be the next turn the provider receives, ahead of any recovery prompt."
        )

        // The recovery prompt and its reply stay visible in the conversation they ran in.
        codexFixtureExecutable = unansweredExecutable.path
        relaunchApp()
        assertTaskVisible("Never settles", inColumn: "Blocked")
        openTask(named: "Never settles")
        XCTAssertTrue(transcriptContains(recoveryMarker), "The recovery prompt Playhouse sent must appear in the visible transcript.")
        try assertAutomaticMessageBubble(taskID: unansweredID, containing: recoveryMarker)
        XCTAssertTrue(transcriptContains("Fixture internal reminder reply."), "The reply to the recovery prompt must appear in the visible transcript.")
        attachScreenshot(named: "Recovery prompt shown as an automatic message")
        for hidden in ["Playhouse private outcome reminder hidden", "Playhouse private outcome response hidden"] {
            XCTAssertEqual(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", hidden)).count, 0,
                "No placeholder replaces the recovery prompt or its reply."
            )
        }
    }
    // case-contract: test_codex_background_command_holds_task_in_progress_until_its_result | A Codex turn that ends without a stopping outcome while a required command it started is still running keeps the task In Progress, with no private prompt, for as long as the command runs, across many more reconciliations of the provider's background terminals than the old five-continuation allowance. When the command ends, Playhouse delivers its real exit status and output to Codex in exactly one private results turn, and the outcome Codex reports there settles the task: Review after a passing command; after a failing command either In Progress again while the agent's rerun is running and Review once the rerun passes, or Blocked with the agent's reason. A command that disappears without a result is reported to the agent as unknown, never as successful. A command still running when Playhouse's wait ceiling passes is reported as still running in the one results turn, is neither terminated nor waited for again, and a turn that ends unsettled after it leaves the task Blocked with the missing-outcome reason. Stopping the task while it waits terminates the command, leaves the task in Waiting Response with no failure reason, and starts no further turn. A turn that reports completed while leaving a command running, as with a dev server, settles in Review at once with no wait, no termination, and no results turn.
    func test_codex_background_command_holds_task_in_progress_until_its_result() throws {
        let resultsMarker = "background work results"
        func fixtureExecutable(_ name: String) -> URL {
            let executable = WorkspaceFixture.root.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "\(name) should be installed.")
            for suffix in [".background-state", ".background-release", ".history"] {
                try? FileManager.default.removeItem(atPath: executable.path + suffix)
            }
            return executable
        }
        func backgroundState(_ executable: URL) -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".background-state")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["running": [String: Any](), "started": 0, "listCalls": 0, "terminated": [String]()]
            }
            return state
        }
        func running(_ state: [String: Any]) -> Int { (state["running"] as? [String: Any])?.count ?? 0 }
        func count(_ state: [String: Any], _ key: String) -> Int { state[key] as? Int ?? 0 }
        func releaseCommand(_ executable: URL, _ result: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: result)
                .write(to: URL(fileURLWithPath: executable.path + ".background-release"), options: .atomic)
        }
        func fixtureTurns(_ executable: URL) throws -> [String] {
            let history = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
            )
            return try XCTUnwrap(history["turns"] as? [[String: Any]]).map { $0["userMessage"] as? String ?? "" }
        }
        func startTurn(_ taskID: String, _ executable: URL, _ extraEnvironment: [String: String] = [:]) throws -> RunningCLIProcess {
            codexFixtureExecutable = executable.path
            return try startCLIProcess(
                ["conversation", "send", taskID, "--message", "Run the required UI test."],
                extraEnvironment: [
                    "PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path,
                    "PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS": "0.2"
                ].merging(extraEnvironment) { _, new in new }
            )
        }
        func status(_ taskID: String) throws -> String? { try taskRecord(id: taskID)?["status"] as? String }

        let passingExecutable = fixtureExecutable("codex-fixture-unique-turns-background-pass")
        codexFixtureExecutable = passingExecutable.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Waits for the UI test", roots: [fixture.primary.path])
        let passingID = try taskID(named: "Waits for the UI test")
        let passing = try startTurn(passingID, passingExecutable)
        defer {
            if passing.process.isRunning {
                try? releaseCommand(passingExecutable, ["exitCode": 0, "output": ""])
                passing.process.waitUntilExit()
            }
        }
        // Far more reconciliations than the five continuation turns that used to end in Blocked.
        XCTAssertTrue(waitUntil({ running(backgroundState(passingExecutable)) == 1 && count(backgroundState(passingExecutable), "listCalls") >= 12 }, timeout: 30),
                      "Playhouse should keep reconciling the running command through the app-server.")
        XCTAssertEqual(try status(passingID), "In Progress", "A required command still running keeps the task In Progress.")
        XCTAssertTrue(passing.process.isRunning, "The send stays open while the command it waits for runs.")
        XCTAssertEqual(try fixtureTurns(passingExecutable).count, 1, "Waiting for a command sends the model no prompts.")
        assertTaskVisible("Waits for the UI test", inColumn: "In Progress")
        attachScreenshot(named: "Task stays In Progress while its background command runs")
        try releaseCommand(passingExecutable, ["exitCode": 0, "output": "Executed 1 test, with 0 failures\n"])
        _ = try finishCLIProcess(passing)
        XCTAssertEqual(try status(passingID), "Review", "The outcome reported from the command's result settles the task.")
        assertTaskVisible("Waits for the UI test", inColumn: "Review")
        let passingTurns = try fixtureTurns(passingExecutable)
        XCTAssertEqual(passingTurns.count, 2, "The command's result is delivered in exactly one private turn.")
        for expected in [resultsMarker, "scripts/test-ui-tart.sh --case fixture", "completed, exit code 0", "Executed 1 test, with 0 failures"] {
            XCTAssertTrue(passingTurns[1].contains(expected), "The results turn should carry \(expected).")
        }
        XCTAssertEqual((backgroundState(passingExecutable)["terminated"] as? [String]) ?? [], [], "A command that ends on its own is never terminated.")
        openTask(named: "Waits for the UI test")
        XCTAssertTrue(transcriptContains("completed, exit code 0"), "The delivered result must appear in the visible transcript.")
        try assertAutomaticMessageBubble(taskID: passingID, containing: "completed, exit code 0")
        attachScreenshot(named: "Background command result delivered as an automatic message")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))

        try createTaskFixture(title: "Fixes the failing UI test", roots: [fixture.primary.path])
        let retryID = try self.taskID(named: "Fixes the failing UI test")
        let retryExecutable = fixtureExecutable("codex-fixture-unique-turns-background-retry")
        let retry = try startTurn(retryID, retryExecutable)
        defer {
            if retry.process.isRunning {
                try? releaseCommand(retryExecutable, ["exitCode": 0, "output": ""])
                retry.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ running(backgroundState(retryExecutable)) == 1 && count(backgroundState(retryExecutable), "listCalls") >= 2 }, timeout: 30),
                      "The first run should be waited for.")
        try releaseCommand(retryExecutable, ["exitCode": 1, "output": "XCTAssertEqual failed: fixture regression\n"])
        XCTAssertTrue(waitUntil({ count(backgroundState(retryExecutable), "started") == 2 && running(backgroundState(retryExecutable)) == 1 }, timeout: 30),
                      "The agent should rerun the command after reading its failure.")
        XCTAssertEqual(try status(retryID), "In Progress", "A rerun that is running keeps the task In Progress.")
        try releaseCommand(retryExecutable, ["exitCode": 0, "output": "Executed 1 test, with 0 failures\n"])
        _ = try finishCLIProcess(retry)
        XCTAssertEqual(try status(retryID), "Review")
        assertTaskVisible("Fixes the failing UI test", inColumn: "Review")
        let retryTurns = try fixtureTurns(retryExecutable)
        XCTAssertEqual(retryTurns.count, 3, "Each command result is delivered once: the failure, then the passing rerun.")
        XCTAssertTrue(retryTurns[1].contains("failed, exit code 1"))
        XCTAssertTrue(retryTurns[1].contains("XCTAssertEqual failed: fixture regression"))
        XCTAssertTrue(retryTurns[2].contains("completed, exit code 0"))
        XCTAssertFalse(retryTurns[2].contains("XCTAssertEqual failed"), "A delivered result is not delivered again.")

        try createTaskFixture(title: "Cannot fix the UI test", roots: [fixture.primary.path])
        let failingID = try self.taskID(named: "Cannot fix the UI test")
        let failingExecutable = fixtureExecutable("codex-fixture-unique-turns-background-fail")
        let failing = try startTurn(failingID, failingExecutable)
        defer {
            if failing.process.isRunning {
                try? releaseCommand(failingExecutable, ["exitCode": 1, "output": ""])
                failing.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ running(backgroundState(failingExecutable)) == 1 && count(backgroundState(failingExecutable), "listCalls") >= 2 }, timeout: 30),
                      "The failing run should be waited for.")
        try releaseCommand(failingExecutable, ["exitCode": 1, "output": "XCTAssertEqual failed: fixture regression\n"])
        _ = try finishCLIProcess(failing, expectedStatus: nil)
        let failingRecord = try XCTUnwrap(taskRecord(id: failingID))
        XCTAssertEqual(failingRecord["status"] as? String, "Blocked")
        XCTAssertTrue((failingRecord["statusMessage"] as? String)?.contains("The required UI test failed") == true)
        XCTAssertEqual(try fixtureTurns(failingExecutable).count, 2)
        assertTaskVisible("Cannot fix the UI test", inColumn: "Blocked")
        let failingCardMessage = element("task-status-message-\(failingID)")
        XCTAssertTrue(failingCardMessage.waitToExist(timeout: 10), "The Blocked card should show the agent's reason.")
        XCTAssertTrue(accessibleLabelOrValue(of: failingCardMessage).contains("The required UI test failed"))
        attachScreenshot(named: "Failed background command ends in Blocked with the agent's reason")

        try createTaskFixture(title: "Loses the UI test", roots: [fixture.primary.path])
        let vanishedID = try self.taskID(named: "Loses the UI test")
        let vanishedExecutable = fixtureExecutable("codex-fixture-unique-turns-background-vanish")
        let vanished = try startTurn(vanishedID, vanishedExecutable)
        defer {
            if vanished.process.isRunning {
                try? releaseCommand(vanishedExecutable, ["vanish": true])
                vanished.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ running(backgroundState(vanishedExecutable)) == 1 && count(backgroundState(vanishedExecutable), "listCalls") >= 2 }, timeout: 30),
                      "The vanishing run should be waited for.")
        try releaseCommand(vanishedExecutable, ["vanish": true])
        _ = try finishCLIProcess(vanished, expectedStatus: nil)
        let vanishedTurns = try fixtureTurns(vanishedExecutable)
        XCTAssertEqual(vanishedTurns.count, 2)
        XCTAssertTrue(vanishedTurns[1].contains("Playhouse did not see its result"))
        XCTAssertFalse(vanishedTurns[1].contains("exit code 0"), "A command gone from the list is not assumed to have passed.")
        let vanishedRecord = try XCTUnwrap(taskRecord(id: vanishedID))
        XCTAssertEqual(vanishedRecord["status"] as? String, "Blocked")
        XCTAssertTrue((vanishedRecord["statusMessage"] as? String)?.contains("without a result") == true)
        assertTaskVisible("Loses the UI test", inColumn: "Blocked")

        try createTaskFixture(title: "Stopped while waiting", roots: [fixture.primary.path])
        let stoppedID = try self.taskID(named: "Stopped while waiting")
        let stoppedExecutable = fixtureExecutable("codex-fixture-unique-turns-background-stop")
        let stopped = try startTurn(stoppedID, stoppedExecutable)
        defer {
            if stopped.process.isRunning {
                try? releaseCommand(stoppedExecutable, ["exitCode": 0, "output": ""])
                stopped.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ running(backgroundState(stoppedExecutable)) == 1 && count(backgroundState(stoppedExecutable), "listCalls") >= 2 }, timeout: 30),
                      "The run should be waited for before the Stop.")
        _ = try runCLI(["conversation", "stop", stoppedID])
        _ = try finishCLIProcess(stopped, expectedStatus: nil)
        XCTAssertEqual(try status(stoppedID), "Waiting Response", "A Stop during the wait keeps the user's paused state.")
        XCTAssertNil(try taskRecord(id: stoppedID)?["statusMessage"] as? String, "A user-requested Stop must not be reported as a failure.")
        XCTAssertEqual(backgroundState(stoppedExecutable)["terminated"] as? [String], ["49264"], "Stop ends the command the task was waiting for.")
        XCTAssertEqual(try fixtureTurns(stoppedExecutable).count, 1, "Nothing restarts the work after a Stop.")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(try fixtureTurns(stoppedExecutable).count, 1, "Nothing restarts the work after a Stop.")
        XCTAssertEqual(try status(stoppedID), "Waiting Response")
        assertTaskVisible("Stopped while waiting", inColumn: "Waiting Response")

        try createTaskFixture(title: "Leaves a dev server running", roots: [fixture.primary.path])
        let serverID = try self.taskID(named: "Leaves a dev server running")
        let serverExecutable = fixtureExecutable("codex-fixture-unique-turns-background-server")
        let server = try startTurn(serverID, serverExecutable)
        defer {
            if server.process.isRunning {
                try? releaseCommand(serverExecutable, ["exitCode": 0, "output": ""])
                server.process.waitUntilExit()
            }
        }
        _ = try finishCLIProcess(server)
        XCTAssertEqual(try status(serverID), "Review", "A completed outcome settles the task even with a command left running.")
        let serverState = backgroundState(serverExecutable)
        XCTAssertEqual(running(serverState), 1, "The dev server keeps running.")
        XCTAssertEqual((serverState["terminated"] as? [String]) ?? [], [])
        XCTAssertEqual(try fixtureTurns(serverExecutable).count, 1, "A settled task gets no results turn.")
        assertTaskVisible("Leaves a dev server running", inColumn: "Review")

        try createTaskFixture(title: "Outlasts the wait", roots: [fixture.primary.path])
        let outlastingID = try self.taskID(named: "Outlasts the wait")
        let outlastingExecutable = fixtureExecutable("codex-fixture-unique-turns-background-timeout")
        let outlasting = try startTurn(outlastingID, outlastingExecutable, ["PLAYHOUSE_E2E_BACKGROUND_JOB_WAIT_SECONDS": "1.5"])
        defer {
            if outlasting.process.isRunning {
                try? releaseCommand(outlastingExecutable, ["exitCode": 0, "output": ""])
                outlasting.process.waitUntilExit()
            }
        }
        _ = try finishCLIProcess(outlasting, expectedStatus: nil)
        let outlastingTurns = try fixtureTurns(outlastingExecutable)
        XCTAssertEqual(outlastingTurns.count, 2, "A command that outlasts the wait earns one prompt and is not waited for again.")
        for expected in [resultsMarker, "still running. Playhouse stopped waiting for it.", "ran longer than Playhouse waits for a command"] {
            XCTAssertTrue(outlastingTurns[1].contains(expected), "The results turn should carry \(expected).")
        }
        XCTAssertFalse(outlastingTurns[1].contains("exit code"), "A command still running has no result to report.")
        let outlastingRecord = try XCTUnwrap(taskRecord(id: outlastingID))
        XCTAssertEqual(outlastingRecord["status"] as? String, "Blocked", "An unsettled turn after the wait ran out is not left In Progress.")
        XCTAssertTrue((outlastingRecord["statusMessage"] as? String)?.contains("stopped without reporting a stopping outcome") == true)
        let outlastingState = backgroundState(outlastingExecutable)
        XCTAssertEqual(running(outlastingState), 1, "Playhouse does not end a command it merely stopped waiting for.")
        XCTAssertEqual((outlastingState["terminated"] as? [String]) ?? [], [])
        assertTaskVisible("Outlasts the wait", inColumn: "Blocked")
        let outlastingCardMessage = element("task-status-message-\(outlastingID)")
        XCTAssertTrue(outlastingCardMessage.waitToExist(timeout: 10), "The Blocked card should say no outcome was reported.")
        XCTAssertTrue(accessibleLabelOrValue(of: outlastingCardMessage).contains("stopped without reporting a stopping outcome"))
        attachScreenshot(named: "Board after background command outcomes settle")
    }
    // case-contract: test_codex_follow_up_queued_during_background_wait_runs_next | A follow-up the user queues while a task waits for a command its Codex turn left running ends the wait at once: the follow-up is the next turn the provider receives, ahead of any results or recovery prompt, and the command is neither terminated nor forgotten. When the follow-up's turn ends without a stopping outcome the task stays In Progress and Playhouse waits for the same command again, with no further prompt. When the command ends, its real exit status and output are delivered once in one private results turn, and the outcome Codex reports there settles the task in Review. The follow-up appears once in history.
    func test_codex_follow_up_queued_during_background_wait_runs_next() throws {
        let resultsMarker = "background work results"
        let recoveryMarker = "ended without reporting a task outcome"
        let followUp = "Also keep the fixture log."
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-background-queue")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "The background queue fixture should be installed.")
        for suffix in [".background-state", ".background-release", ".history"] {
            try? FileManager.default.removeItem(atPath: executable.path + suffix)
        }
        func backgroundState() -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".background-state")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return state
        }
        func running() -> Int { (backgroundState()["running"] as? [String: Any])?.count ?? 0 }
        func count(_ key: String) -> Int { backgroundState()[key] as? Int ?? 0 }
        func releaseCommand(_ result: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: result)
                .write(to: URL(fileURLWithPath: executable.path + ".background-release"), options: .atomic)
        }
        func fixtureTurns() -> [String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).map { $0["userMessage"] as? String ?? "" }
        }

        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Follow-up while waiting", roots: [fixture.primary.path])
        let taskID = try self.taskID(named: "Follow-up while waiting")
        let turn = try startCLIProcess(
            ["conversation", "send", taskID, "--message", "Run the required UI test."],
            extraEnvironment: [
                "PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path,
                "PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS": "0.2"
            ]
        )
        defer {
            if turn.process.isRunning {
                try? releaseCommand(["exitCode": 0, "output": ""])
                turn.process.waitUntilExit()
            }
        }
        XCTAssertTrue(waitUntil({ running() == 1 && count("listCalls") >= 2 }, timeout: 30), "The command should be waited for before the follow-up.")
        XCTAssertEqual(fixtureTurns().count, 1)
        _ = try runCLI(["conversation", "queue", taskID, "--message", followUp])
        XCTAssertTrue(waitUntil({ fixtureTurns().count >= 2 }, timeout: 30), "The queued follow-up should end the wait and run as the next turn.")
        var turns = fixtureTurns()
        XCTAssertTrue(turns[1].contains(followUp), "The follow-up is the next turn the provider receives.")
        XCTAssertFalse(turns[1].contains(resultsMarker))
        XCTAssertFalse(turns[1].contains(recoveryMarker))
        let callsAfterFollowUp = count("listCalls")
        XCTAssertTrue(waitUntil({ running() == 1 && count("listCalls") >= callsAfterFollowUp + 3 }, timeout: 30),
                      "The same command should be waited for again after the follow-up's turn.")
        XCTAssertEqual(count("started"), 1, "The follow-up starts no second command.")
        XCTAssertEqual((backgroundState()["terminated"] as? [String]) ?? [], [], "A queued follow-up does not terminate the command.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "The command still running keeps the task In Progress after the follow-up.")
        XCTAssertEqual(fixtureTurns().count, 2, "Waiting again sends the model no prompt.")
        assertTaskVisible("Follow-up while waiting", inColumn: "In Progress")
        openTask(named: "Follow-up while waiting")
        XCTAssertTrue(waitUntil({ self.transcriptContains(followUp) }, timeout: 15), "The follow-up must appear in the visible transcript.")
        attachScreenshot(named: "Follow-up answered while the command is still waited for")

        try releaseCommand(["exitCode": 0, "output": "Executed 1 test, with 0 failures\n"])
        XCTAssertTrue(waitForStatus(taskID, "Review", timeout: 60), "The outcome reported from the command's result should settle the task.")
        turn.process.waitUntilExit()
        turns = fixtureTurns()
        XCTAssertEqual(turns.count, 3, "The command's result is delivered in exactly one private turn after the follow-up.")
        XCTAssertEqual(turns.filter { $0.contains(resultsMarker) }.count, 1)
        XCTAssertTrue(turns[2].contains("completed, exit code 0"))
        XCTAssertTrue(turns[2].contains("Executed 1 test, with 0 failures"))
        XCTAssertFalse(turns.contains { $0.contains(recoveryMarker) }, "No recovery prompt is sent while a command is waited for.")
        XCTAssertEqual((backgroundState()["terminated"] as? [String]) ?? [], [])
        XCTAssertEqual(try historyTexts(taskID: taskID).filter { $0.contains(followUp) }.count, 1, "The follow-up appears once in history.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("completed, exit code 0") }, timeout: 15), "The delivered result must appear in the visible transcript.")
        attachScreenshot(named: "Command result delivered once after the follow-up")
        assertTaskVisible("Follow-up while waiting", inColumn: "Review")
        attachScreenshot(named: "Review card after the follow-up and the command result")
    }
}

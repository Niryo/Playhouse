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
    // case-contract: test_claude_settles_turn_after_consumed_wake_notification | When Claude Code starts the provider turn that would deliver a finished background task's notification and then says nothing at all, Playhouse settles that turn on its own instead of leaving it open and the task In Progress forever: a follow-up queued while the turn was still parked stays queued through the silent wake, the send finishes and the task reaches Review, and that follow-up is then delivered in its own turn rather than stranded in the queue. A woken turn that is alive and merely slow to speak is not cut off by that backstop: it stays quiet past the grace a consumed notification gets and still ends the turn on its own answer.
    func test_claude_settles_turn_after_consumed_wake_notification() throws {
        let executable = try installClaudeFixtureExecutable(named: "claude-fixture-consumed-wake")
        let pause = URL(fileURLWithPath: executable.path + ".consumed-wake-pause")
        let parked = URL(fileURLWithPath: executable.path + ".consumed-wake-ready")
        let release = URL(fileURLWithPath: executable.path + ".consumed-wake-release")
        let woken = URL(fileURLWithPath: executable.path + ".consumed-wake-woken")
        try Data().write(to: pause, options: .atomic)
        defer {
            try? Data("Release the consumed-wake fixture pause.\n".utf8).write(to: release, options: .atomic)
            try? FileManager.default.removeItem(at: pause)
        }
        // Short graces keep the case inside the runner's time allowance; which
        // silence settles the turn and which one waits for Claude does not
        // depend on their lengths.
        let graceEnvironment = [
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS": "4",
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS": "24",
            "PLAYHOUSE_E2E_CLAUDE_SLOW_WOKEN_SILENCE_SECONDS": "8",
        ]
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude consumed wake", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        let slowCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude slow woken turn", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let slowTaskID = try XCTUnwrap(slowCreated["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: graceEnvironment)
        openTask(named: "Claude consumed wake")
        element("message-composer").click()
        element("message-composer").typeText("Park a shell and then consumed wake notification.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: parked.path) }, timeout: 20),
                      "The fixture should park the turn after its result while the shell runs.")
        XCTAssertTrue(waitUntil({ self.element("pause-response-button").exists }, timeout: 10),
                      "The parked turn must read as the active turn while the shell runs.")

        // The turn is still active, so this follow-up queues rather than sends;
        // only a settled turn can ever deliver it.
        let stranded = "Then tell the story of the VM run."
        let composer = element("message-composer")
        composer.click()
        composer.typeText(stranded)
        composer.typeKey(.return, modifierFlags: [])
        let queued = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let queuedID = try XCTUnwrap(queued?.first(where: { $0["text"] as? String == stranded })?["id"] as? String)
        XCTAssertTrue(element("queued-message-text-\(queuedID)").waitToExist(timeout: 10),
                      "A follow-up sent while the parked turn is active must wait in the queue.")

        try Data("Release the consumed-wake fixture pause.\n".utf8).write(to: release, options: .atomic)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: woken.path) }, timeout: 20),
                      "The fixture should start the woken turn and then stay silent.")
        XCTAssertTrue(element("pause-response-button").exists,
                      "The silently consumed wake leaves the turn active until Playhouse's own grace period settles it.")
        XCTAssertTrue(element("queued-message-text-\(queuedID)").exists,
                      "A stranded turn takes no further input, so the follow-up is still waiting here.")
        attachScreenshot(named: "Turn still active and the follow-up still queued after the silently consumed wake")

        // Only the woken-turn silence grace can end this turn, so wait past it.
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 60),
                      "Playhouse must settle a turn stranded by a silently consumed wake instead of leaving it active forever.")
        XCTAssertTrue(transcriptContains("WAKE SHELL STARTED"),
                      "Settling a stranded turn must keep the answer it already gave.")
        attachScreenshot(named: "Playhouse settled the stranded turn by itself")

        XCTAssertTrue(waitUntil({ self.transcriptContains("BISCUIT-7") }, timeout: 60),
                      "A follow-up queued while the turn was stranded must be delivered once Playhouse settles it.")
        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])??
                .contains { $0["id"] as? String == queuedID } == false
        }, timeout: 30), "The delivered follow-up must leave the queue.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["task", "get", taskID])["result"] as? [String: Any])??["status"] as? String) == "Review"
        }, timeout: 60), "A task whose turn was stranded must not stay In Progress once Playhouse settles it.")
        attachScreenshot(named: "Delivered follow-up answered and the task out of In Progress")

        // A woken turn that is alive and merely slow to speak must not be cut
        // off by that same backstop: it gets its own, far longer grace.
        let announced = URL(fileURLWithPath: executable.path + ".slow-woken-announced")
        openTask(named: "Claude slow woken turn")
        element("message-composer").click()
        element("message-composer").typeText("Park a shell and then a slow woken turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: announced.path) }, timeout: 30),
                      "The fixture should announce the woken turn before going quiet.")
        // The fixture announces within moments of the send, so give the window a beat to
        // draw the active turn; the woken turn stays quiet for far longer than this.
        XCTAssertTrue(waitUntil({ self.element("pause-response-button").exists }, timeout: 5),
                      "A woken turn that has only just announced itself is still the active turn.")
        attachScreenshot(named: "Slow woken turn announced itself and is still the active turn while it stays quiet")
        XCTAssertTrue(waitUntil({ self.transcriptContains("SLOW WOKEN HANDLED") }, timeout: 60),
                      "A woken turn quiet past the consumed-notification grace must still end on its own answer.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30),
                      "Claude's own answer ends the slow woken turn.")
        attachScreenshot(named: "Slow woken turn answered instead of being cut off by the backstop")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["task", "get", slowTaskID])["result"] as? [String: Any])??["status"] as? String) == "Review"
        }, timeout: 60), "The slow woken turn's own completed outcome should move its task to Review.")
    }
    // case-contract: test_claude_stopping_outcome_decides_over_background_work | A Claude turn that reports completed and then leaves a background shell running, a dev server, settles in Review as soon as Claude's result arrives, without waiting for a notification that never comes and without a recovery prompt. A completed outcome reported while a background agent is still running does not settle the turn: the task stays In Progress while the agent runs, and when the woken parent turn then does more work and ends without a new report, the earlier outcome is treated as stale, so the task does not reach Review; Playhouse sends exactly one recovery prompt and the outcome reported in it places the task in Waiting Response. When Claude Code starts the woken turn for a finished background shell and then stays silent, with no outcome reported and no queued follow-up, Playhouse's backstop ends the wait and the same single recovery prompt decides the task's column instead of leaving it In Progress. The UI shows each task in the matching column and the recovery prompt in the transcript.
    func test_claude_stopping_outcome_decides_over_background_work() throws {
        let executable = try installClaudeFixtureExecutable(named: "claude-fixture-stopping-outcome")
        let pause = URL(fileURLWithPath: executable.path + ".early-report-pause")
        let ready = URL(fileURLWithPath: executable.path + ".early-report-ready")
        let release = URL(fileURLWithPath: executable.path + ".early-report-release")
        let woken = URL(fileURLWithPath: executable.path + ".consumed-wake-woken")
        let serverResult = URL(fileURLWithPath: executable.path + ".dev-server-result-sent")
        try Data().write(to: pause, options: .atomic)
        defer {
            try? Data("Release the early-report fixture pause.\n".utf8).write(to: release, options: .atomic)
            try? FileManager.default.removeItem(at: pause)
        }
        let graceEnvironment = [
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS": "2",
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS": "3",
        ]
        func create(_ title: String) throws -> String {
            let created = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
            ])["result"] as? [String: Any])
            return try XCTUnwrap(created["id"] as? String)
        }
        func status(_ taskID: String) -> String? {
            (try? self.taskRecord(id: taskID))??["status"] as? String
        }
        func nudges() throws -> [String] {
            let data = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
            let history = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return ((history["turns"] as? [[String: Any]]) ?? [])
                .compactMap { $0["userText"] as? String }
                .filter { $0.lowercased().contains("playhouse internal outcome nudge:") }
        }
        func send(_ text: String) {
            element("message-composer").click()
            element("message-composer").typeText(text)
            element("send-message-button").click()
            // The fixture can answer before the composer clears the sent draft, and while the draft
            // is there the composer's button is Send, not Stop.
            XCTAssertTrue(waitUntil({ ((self.element("message-composer").value as? String) ?? "").isEmpty }, timeout: 5),
                          "Sending clears the composer's draft.")
        }
        let serverID = try create("Claude dev server")
        let earlyID = try create("Claude early report")
        let silentID = try create("Claude silent wake")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: graceEnvironment)

        // A reported outcome settles the turn even with a shell left running.
        openTask(named: "Claude dev server")
        send("Please leave-dev-server-running.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: serverResult.path) }, timeout: 20),
                      "The fixture should report its outcome and result with the dev server still running.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20),
                      "A reported stopping outcome ends the turn without waiting for the dev server.")
        XCTAssertTrue(waitUntil({ status(serverID) == "Review" }, timeout: 20),
                      "A reported outcome settles the task even with a shell left running.")
        XCTAssertTrue(transcriptContains("DEV SERVER RUNNING"))
        XCTAssertEqual(try nudges().count, 0, "A reported stopping outcome needs no recovery prompt.")
        attachScreenshot(named: "Completed outcome ends the turn with the dev server still running")
        element("back-to-board-button").click()
        assertTaskVisible("Claude dev server", inColumn: "Review")

        // An outcome reported while a background agent runs does not settle the turn.
        openTask(named: "Claude early report")
        send("Please report-early-then-continue.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20),
                      "The fixture should pause after its early outcome and result.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("REPORTED EARLY") }, timeout: 10))
        XCTAssertTrue(element("pause-response-button").exists,
                      "A running background agent keeps the turn open even after an outcome report.")
        XCTAssertEqual(status(earlyID), "In Progress", "The early outcome must not move the task while the agent runs.")
        attachScreenshot(named: "Turn stays active while the background agent runs after an early outcome")
        try Data("Finish the background agent.\n".utf8).write(to: release, options: .atomic)
        XCTAssertTrue(waitUntil({ self.transcriptContains("MORE WORK FOUND") }, timeout: 30),
                      "The woken parent turn's further work belongs in the conversation.")
        XCTAssertTrue(waitUntil({ status(earlyID) == "Waiting Response" }, timeout: 60),
                      "The stale completed report must not reach Review; the recovery prompt's outcome decides.")
        XCTAssertEqual(try nudges().count, 1, "The woken turn that ended unreported earns exactly one recovery prompt.")
        XCTAssertTrue(try XCTUnwrap(try nudges().first).contains("This is the only recovery prompt"))
        _ = try assertAutomaticMessageBubble(taskID: earlyID, containing: "ended without reporting a task outcome")
        attachScreenshot(named: "Recovery prompt after the woken turn ended without a new outcome")
        element("back-to-board-button").click()
        assertTaskVisible("Claude early report", inColumn: "Waiting Response")

        // A silently consumed wake ends in the single recovery prompt, not In Progress forever.
        openTask(named: "Claude silent wake")
        send("Park a shell and then consumed wake notification.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: woken.path) }, timeout: 20),
                      "The fixture should start the woken turn and then stay silent.")
        XCTAssertTrue(waitUntil({ status(silentID) == "Waiting Response" }, timeout: 90),
                      "A lost wake ends in the column the recovery prompt's outcome names, not In Progress forever.")
        XCTAssertEqual(try nudges().count, 2, "The lost wake earns exactly one recovery prompt of its own.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20))
        element("back-to-board-button").click()
        assertTaskVisible("Claude silent wake", inColumn: "Waiting Response")
        assertTaskVisible("Claude dev server", inColumn: "Review")
        attachScreenshot(named: "Board after the Claude stopping outcomes settle")
    }
    // case-contract: test_claude_private_recovery_failure_fails_closed | If Claude fails while applying an answer after restart and echoes the answer or recovery instructions, Playhouse returns a generic error, preserves the pending question for retry while the task stays in Waiting Response, stores and shows the prompt that carried the answer as sent, and keeps it out of saved task state and diagnostics.
    func test_claude_private_recovery_failure_fails_closed() throws {
        let executable = try installClaudeFixtureExecutable(named: "claude-fixture-recovery-failure")
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude private recovery failure", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude private recovery failure")
        element("message-composer").click()
        element("message-composer").typeText("Ask a restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Claude private recovery failure")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        try "Playhouse owns this Claude fixture marker.\n".write(
            to: URL(fileURLWithPath: executable.path + ".recovery-error"),
            atomically: true,
            encoding: .utf8
        )
        selectQuestionOption(identifier: "ai-question-option-question-1-Green")
        element("submit-ai-answers-button").click()
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 15))
        XCTAssertEqual(error.label, "The private answer could not be applied. Please answer the question again.")
        XCTAssertTrue(element("conversation-user-input-request").exists)
        // The prompt that carried the answer was sent, so it is stored and shown as sent.
        XCTAssertTrue(waitUntil({ self.transcriptContains("Answer: Green") }, timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response",
                       "An unanswered question stays available for retry after a failed recovery attempt.")
        XCTAssertFalse((try taskRecord(id: taskID)?["savedPrompt"] as? String ?? "").contains("Answer: Green"),
            "Saved task state stays free of the private answer.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude private recovery failure", inColumn: "Waiting Response")
        openTask(named: "Claude private recovery failure")
        XCTAssertTrue(element("conversation-user-input-request").exists)
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Claude private recovery failure")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude private recovery failure", inColumn: "Waiting Response")
        openTask(named: "Claude private recovery failure")
        XCTAssertTrue(element("conversation-user-input-request").exists)
        XCTAssertTrue(waitUntil({ self.transcriptContains("Answer: Green") }, timeout: 10), "The sent prompt survives an app restart.")
    }
    // case-contract: test_codex_pending_question_recovers_after_provider_process_restarts | Codex's pending structured question persists after its provider process exits and leaves the task in Waiting Response while unanswered; Playhouse restores it from fresh CLI/XPC history, keeps provider switching blocked, requires the user to re-enter the secret once, and applies the answers in one recovery turn. The live recovery stream and the stored transcript carry the recovery prompt, assistant response, activities, and diffs exactly as sent, including the re-entered secret with its surrounding whitespace, and the visible UI shows them immediately and after app restart; saved task state stays free of the secret. A later Codex turn keeps its own diff and response visible in refreshed CLI/UI history alongside the earlier recovery response. In one task, a no-secret recovery response remains visible after a later secret recovery. The first prompt, delivered before the provider exited although its send reported failure, is in history, never returns to the composer, and is not saved as an unsent draft.
    func test_codex_pending_question_recovers_after_provider_process_restarts() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-restart-question")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        try "Playhouse test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Restart-safe Codex question", "--prompt", "Fixture task description.", "--root", fixture.primary.path
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Restart-safe Codex question")
        element("message-composer").click()
        element("message-composer").typeText("Ask a restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        // The fixture exits right after asking, so the send reports failure; wait until the app
        // has handled it, or the checks below could pass before the handler runs.
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "The provider exit should be reported in the conversation.")
        XCTAssertTrue(transcriptMessage("Ask a restart-safe structured question.").exists,
            "The prompt Codex received stays in the conversation after its send reports failure.")
        XCTAssertEqual(element("message-composer").value as? String, "",
            "The prompt Codex received must not return to the composer.")
        attachScreenshot(named: "Delivered prompt stays in the conversation while the composer is empty")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Restart-safe Codex question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["hasUnsentDraft"] as? Bool, false,
            "A prompt the provider received before it exited must not be saved as an unsent draft.")
        XCTAssertTrue(transcriptMessage("Ask a restart-safe structured question.").exists,
            "After restart the delivered prompt is still in the conversation.")
        attachScreenshot(named: "After restart the pending question shows with the delivered prompt")
        XCTAssertFalse(element("conversation-provider-menu").isEnabled, "A saved structured question must block provider switching after restart.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Restart-safe Codex question", inColumn: "Waiting Response")
        openTask(named: "Restart-safe Codex question")
        XCTAssertTrue(element("conversation-user-input-request").exists)

        selectQuestionOption(identifier: "ai-question-option-color-Green")
        let secretAnswer = element("ai-question-answer-token")
        secretAnswer.click()
        secretAnswer.typeText(" fixture-secret ")
        element("submit-ai-answers-button").click()
        let recoveryAnswer = "Recovered answer: Green; private token fixture-secret was applied."
        XCTAssertTrue(transcriptMessage(recoveryAnswer).waitToExist(timeout: 15),
            "The recovery response is shown as Codex sent it.")
        XCTAssertTrue(transcriptContains("Question: What is the private token?"),
            "The prompt that carried the re-entered answers is shown as sent.")
        let shownPrompt = NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)",
                                      "Question: What is the private token?", "fixture-secret", "Question: What is the private token?", "fixture-secret")
        XCTAssertTrue(app.descendants(matching: .any).matching(shownPrompt).firstMatch.exists,
            "The shown recovery prompt carries the re-entered answer as sent.")
        let storedPrompts = try XCTUnwrap((try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
            .filter { $0["role"] as? String == "user" }.compactMap { $0["text"] as? String }
            .filter { $0.contains("Question: What is the private token?") }
        XCTAssertEqual(storedPrompts.count, 1, "The recovery prompt is stored once.")
        XCTAssertTrue(storedPrompts.first?.contains("Answer:  fixture-secret") == true, "The re-entered answer is stored exactly as sent.")
        XCTAssertFalse((try taskRecord(id: taskID)?["savedPrompt"] as? String ?? "").contains("fixture-secret"),
            "Saved task state stays free of the secret.")
        XCTAssertFalse(element("conversation-user-input-request").exists)
        let providerHistory = try String(contentsOf: URL(fileURLWithPath: executable.path + ".history"), encoding: .utf8)
        XCTAssertTrue(providerHistory.contains("Green"))
        XCTAssertTrue(providerHistory.contains("fixture-secret"))
        attachScreenshot(named: "Recovery prompt and response are shown as sent")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Restart-safe Codex question")
        XCTAssertTrue(transcriptMessage(recoveryAnswer).waitToExist(timeout: 15),
            "After restart, the stored transcript shows the recovery response as sent.")
        XCTAssertTrue(transcriptContains("Question: What is the private token?"),
            "After restart, the stored transcript shows the recovery prompt as sent.")
        let persistedActivityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(expandActivityDetails(persistedActivityDisclosure),
            "The reloaded check must inspect expanded activity details.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "printf fixture-secret")).firstMatch.waitToExist(timeout: 5),
            "Recovery activities are stored and shown as Codex sent them.")
        attachScreenshot(named: "After restart the stored recovery turn and its activity are shown as sent")

        let followUpComposer = element("message-composer")
        XCTAssertEqual(followUpComposer.value as? String, "",
            "The delivered first prompt must not come back to the composer after restarts.")
        followUpComposer.click()
        followUpComposer.typeText("Follow up after private recovery.")
        element("send-message-button").click()
        XCTAssertTrue(app.staticTexts["Follow-up after private recovery complete."].waitToExist(timeout: 15),
            "A normal follow-up after recovery should remain visible in the refreshed conversation.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 30),
            "The follow-up with no reported outcome should finish after two hidden reminders.")
        let followUpHistory = try runCLI(["conversation", "history", taskID])
        let followUpMessages = try XCTUnwrap((followUpHistory["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(followUpMessages.contains { ($0["text"] as? String) == "Follow-up after private recovery complete." },
            "Fresh UI-backed history should retain the follow-up response.")
        XCTAssertTrue(followUpMessages.contains { ($0["text"] as? String) == recoveryAnswer },
            "Fresh history after a later turn keeps the earlier recovery response.")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Restart-safe Codex question")
        XCTAssertTrue(app.staticTexts["Follow-up after private recovery complete."].waitToExist(timeout: 15),
            "The follow-up response should remain visible after reopening the stored transcript.")

        let noSecretExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-restart-question-no-secret")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: noSecretExecutable.path))
        codexFixtureExecutable = noSecretExecutable.path
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        try createTaskFixture(title: "Codex recovery without a secret", roots: [fixture.primary.path])
        let noSecretTaskID = try XCTUnwrap(taskRecord(named: "Codex recovery without a secret")?["id"] as? String)
        openTask(named: "Codex recovery without a secret")
        let noSecretComposer = element("message-composer")
        noSecretComposer.click()
        noSecretComposer.typeText("Ask a restart-safe non-secret question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Codex recovery without a secret")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "private token")).firstMatch.exists)
        selectQuestionOption(identifier: "ai-question-option-color-Blue")
        element("submit-ai-answers-button").click()
        let noSecretAnswer = transcriptMessage("Recovered answer: Blue; no secret was required.")
        XCTAssertTrue(noSecretAnswer.waitToExist(timeout: 15), "Codex recovery without secret answers should preserve its response.")
        XCTAssertEqual(try taskRecord(id: noSecretTaskID)?["status"] as? String, "Waiting Response")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Codex recovery without a secret")
        XCTAssertTrue(transcriptMessage("Recovered answer: Blue; no secret was required.").waitToExist(timeout: 15),
            "The safe answer should remain visible after reopening a non-secret recovery conversation.")

        let secondQuestionComposer = element("message-composer")
        secondQuestionComposer.click()
        secondQuestionComposer.typeText("Ask a second restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["What is the private token?"].exists)
        selectQuestionOption(identifier: "ai-question-option-color-Green")
        let tokenAnswer = element("ai-question-answer-token")
        tokenAnswer.click()
        tokenAnswer.typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(transcriptMessage("Recovered answer: Green; private token fixture-secret was applied.").waitToExist(timeout: 15))
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Codex recovery without a secret")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        // Earlier rows render only near the viewport, so these checks scan the whole transcript.
        XCTAssertTrue(transcriptScan { self.transcriptMessage("Recovered answer: Blue; no secret was required.").exists },
            "A later secret recovery must leave the earlier no-secret response visible after restart.")
        XCTAssertTrue(transcriptScan { self.transcriptMessage("Recovered answer: Green; private token fixture-secret was applied.").exists },
            "The later recovery response stays stored as sent after restart.")
    }
    // case-contract: test_codex_secret_recovery_redaction_fails_closed | When Codex fails while applying recovered answers, Playhouse preserves the pending question while the task stays in Waiting Response, uses a generic visible error, stores and shows the sent recovery prompt as sent, and keeps the secret out of saved task state, diagnostics, and error text; later Codex thread read and resume failures do not affect history, which loads from Playhouse's own transcript store across fresh CLI/XPC reads and app restarts.
    func test_codex_secret_recovery_redaction_fails_closed() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unassociated-restart-question")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        try "Playhouse test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Fail-closed secret recovery", "--prompt", "Fixture task description.", "--root", fixture.primary.path
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Fail-closed secret recovery")
        element("message-composer").click()
        element("message-composer").typeText("Ask a restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Fail-closed secret recovery")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        try "Playhouse owns this Codex fixture failure marker.\n".write(
            to: URL(fileURLWithPath: executable.path + ".provider-error-async"),
            atomically: true,
            encoding: .utf8
        )
        selectQuestionOption(identifier: "ai-question-option-color-Green")
        let secretAnswer = element("ai-question-answer-token")
        secretAnswer.click()
        secretAnswer.typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 15))
        XCTAssertEqual(element("codex-chat-error").label, "The private answer could not be applied. Please answer the question again.")
        let shownSecretPrompt = NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)",
                                            "Question: What is the private token?", "fixture-secret", "Question: What is the private token?", "fixture-secret")
        XCTAssertTrue(waitUntil({ self.app.descendants(matching: .any).matching(shownSecretPrompt).firstMatch.exists }, timeout: 10),
            "The prompt that carried the answers was sent, so it is shown as sent, secret included.")
        let failedPrompts = try XCTUnwrap((try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
            .filter { $0["role"] as? String == "user" }.compactMap { $0["text"] as? String }
        XCTAssertTrue(failedPrompts.contains { $0.contains("Question: What is the private token?\nAnswer: fixture-secret") },
            "The prompt that carried the answers is stored as sent.")
        XCTAssertTrue(element("conversation-user-input-request").exists, "A failed recovery must leave the question available to retry.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response",
                       "An unanswered question stays available for retry after a failed recovery attempt.")
        XCTAssertFalse((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("fixture-secret"))
        XCTAssertFalse((try taskRecord(id: taskID)?["savedPrompt"] as? String ?? "").contains("fixture-secret"),
            "Saved task state stays free of the secret.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Fail-closed secret recovery", inColumn: "Waiting Response")
        openTask(named: "Fail-closed secret recovery")
        XCTAssertTrue(element("conversation-user-input-request").exists)

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Fail-closed secret recovery")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ self.app.descendants(matching: .any).matching(shownSecretPrompt).firstMatch.exists }, timeout: 10),
            "The stored transcript keeps the sent prompt after app restart.")
        // History comes from Playhouse's own transcript store, so Codex thread read and resume
        // failures cannot break it.
        try "Playhouse owns this Codex fixture history failure marker.\n".write(
            to: URL(fileURLWithPath: executable.path + ".history-error"),
            atomically: true,
            encoding: .utf8
        )
        try "Playhouse owns this Codex fixture resume failure marker.\n".write(
            to: URL(fileURLWithPath: executable.path + ".resume-error"),
            atomically: true,
            encoding: .utf8
        )
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Fail-closed secret recovery")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15),
            "The unanswered recovery request stays visible when Codex cannot resume the thread.")
        XCTAssertTrue(waitUntil({ self.app.descendants(matching: .any).matching(shownSecretPrompt).firstMatch.exists }, timeout: 10),
            "The stored transcript loads without reading the Codex thread.")
        XCTAssertFalse(element("codex-chat-error").exists, "Opening a conversation does not depend on the Codex thread.")
        attachScreenshot(named: "Stored transcript loads while Codex cannot resume the thread")
    }
    // case-contract: test_claude_questions_can_be_answered_after_switching_conversations | Claude AskUserQuestion requests are delivered through the control path and move the task to Waiting Response while pending; the question's Markdown, including a long paragraph, header, and option descriptions reach the client unchanged, and the UI renders the question inline with its Markdown formatted at the reply text size and its long paragraph wrapped in full across several lines without truncation, its header, and each option's description, preserves it across conversation switching, and sends a later answer to Claude before the turn ends in Waiting Response.
    func test_claude_questions_can_be_answered_after_switching_conversations() throws {
        try installClaudeFixtureExecutable(named: "claude-fixture-question")
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        _ = try runCLI(["task", "create", "--title", "Other provider conversation", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude question")
        element("message-composer").click()
        element("message-composer").typeText("Ask a structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude question", inColumn: "Waiting Response")
        openTask(named: "Other provider conversation")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 5))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude question", inColumn: "Waiting Response")
        openTask(named: "Claude question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 5))
        // The question renders its Markdown at the reply size, under its header, with each option's description.
        let questionContainer = element("ai-question-text-question-1")
        XCTAssertTrue(questionContainer.exists, "The question text should render in its own container.")
        let questionText = questionContainer.staticTexts["Which color should I use for the primary button?"]
        XCTAssertTrue(questionText.exists, "The question's bold Markdown should render without its markers.")
        XCTAssertTrue(questionContainer.staticTexts["It also tints LinkText."].exists, "The question's second paragraph and inline code should render.")
        XCTAssertFalse(
            questionContainer.staticTexts.matching(NSPredicate(format: "label CONTAINS '**' OR label CONTAINS '`'")).firstMatch.exists,
            "Raw Markdown markers must not show in the question."
        )
        // Width scales with the font and, unlike height, excludes the paragraph's bottom padding. With its
        // bold run always 16 points, this line measures about 359 points when its plain text is at the
        // 16-point reply size and about 324 when that text falls back to the 13-point default.
        XCTAssertGreaterThanOrEqual(questionText.frame.width, 345, "The question's plain text should use the 16-point reply size.")
        // A macOS static text reports its string as its value, not its label.
        func shownText(_ identifier: String) -> String {
            let text = element(identifier)
            return text.label + (text.value as? String ?? "")
        }
        // A truncated Text still reports its whole string to accessibility, so its height shows whether it
        // wrapped: this paragraph needs about three lines at the form's width, where the one-line first
        // paragraph above it, measured the same way, would be cut to a single line ending in an ellipsis.
        let longQuestion = "When the user clicks an \"Add here\" placeholder, which conversation should open: the task's active "
            + "conversation, a new conversation started just for that placeholder, or the conversation the placeholder "
            + "was originally added from?"
        let longQuestionText = questionContainer.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "When the user clicks", "When the user clicks")
        ).firstMatch
        XCTAssertTrue(longQuestionText.exists, "The question's long paragraph should render.")
        XCTAssertTrue(
            [longQuestionText.label, longQuestionText.value as? String ?? ""].contains(longQuestion),
            "The long paragraph should carry its full text."
        )
        XCTAssertGreaterThanOrEqual(
            longQuestionText.frame.height, questionText.frame.height * 2,
            "The long paragraph should wrap across several lines instead of truncating to one."
        )
        XCTAssertGreaterThan(longQuestionText.frame.minY, questionText.frame.maxY, "The long paragraph should sit below the first one.")
        XCTAssertGreaterThan(
            element("ai-question-option-question-1-Blue").frame.minY, longQuestionText.frame.maxY,
            "The options should lay out below the whole multi-line question."
        )
        XCTAssertEqual(shownText("ai-question-header-question-1").uppercased(), "COLOR")
        XCTAssertEqual(shownText("ai-question-option-description-question-1-Blue"), "Use blue.")
        XCTAssertEqual(shownText("ai-question-option-description-question-1-Green"), "Use green.")
        attachScreenshot(named: "Claude question with Markdown, a long wrapped paragraph, header, and option descriptions")
        selectQuestionOption(identifier: "ai-question-option-question-1-Blue")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(transcriptMessage("Answer received: Blue.").waitToExist(timeout: 10))
        // The answer renders as it streams; the status moves once the turn ends.
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response"), "The answered turn should end in Waiting Response.")
    }
    // case-contract: test_claude_outcome_reminder_rejects_user_questions | A successful Claude turn with an unanswered AskUserQuestion stays In Progress without outcome nudges; after the user answers, the next successful turn receives a hidden CLI status nudge. A question raised during that nudge is rejected through Claude's control protocol with completed, waiting-response, and keep-working instructions, which fails the private turn; the rejected question and the private rejection instructions stay out of the transcript, while a prompt that applied the user's answer is stored and shown as sent. Playhouse then stops driving the work and marks the task Blocked naming that reason.

    func test_claude_outcome_reminder_rejects_user_questions() throws {
        let executable = try installClaudeFixtureExecutable(named: "claude-fixture-outcome-reminder-question")
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude reminder question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude reminder question")
        element("message-composer").click()
        element("message-composer").typeText("Finish while a structured question remains pending.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        // The question flips the task to Waiting Response at once; the turn then ends with no
        // outcome and restores In Progress so the outcome reminder decides. Read the settled state.
        XCTAssertTrue(waitForStatus(taskID, "In Progress", timeout: 10), "A successful turn with a pending question should settle back in In Progress.")
        let pendingHistory = try runCLI(["conversation", "history", taskID])
        XCTAssertNotNil((pendingHistory["result"] as? [String: Any])?["pendingUserInputRequest"])
        let pendingFixtureHistory = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let pendingTurns = try XCTUnwrap((try JSONSerialization.jsonObject(with: pendingFixtureHistory) as? [String: Any])?["turns"] as? [[String: Any]])
        XCTAssertEqual(pendingTurns.count, 1)
        XCTAssertFalse(pendingTurns.contains { ($0["userText"] as? String)?.contains("Playhouse internal outcome nudge:") == true }, "A successful turn with a pending question must not receive outcome nudges.")
        selectQuestionOption(identifier: "ai-question-option-question-1-Blue")
        element("submit-ai-answers-button").click()
        // The answered turn already settled, so the answer arrives as a recovery turn.
        XCTAssertTrue(transcriptMessage("Recovered answer: Blue.").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ !element("conversation-user-input-request").exists }, timeout: 5))
        element("message-composer").click()
        element("message-composer").typeText("Continue after answering.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked" }, timeout: 60), "A failed private nudge should stop Playhouse driving and settle the task in Blocked.")
        XCTAssertTrue(
            (try taskRecord(id: taskID)?["statusMessage"] as? String)?.contains("couldn't run the private turn") == true,
            "The Blocked reason must name why Playhouse stopped driving the work."
        )

        let fixtureTurnsData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureTurnsData) as? [String: Any])
        let turns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        let nudges = turns.filter { ($0["userText"] as? String)?.contains("Playhouse internal outcome nudge:") == true }
        XCTAssertEqual(nudges.count, 1, "Rejecting the question fails the private turn, so Playhouse stops driving the task.")
        XCTAssertTrue(nudges.allSatisfy { ($0["userText"] as? String)?.contains("task outcome command") == true })
        let rejectionText = try String(contentsOfFile: executable.path + ".private-reminder-question-rejection", encoding: .utf8)
        let rejections = rejectionText.split(whereSeparator: \.isNewline)
        XCTAssertEqual(rejections.count, 1)
        XCTAssertTrue(rejections.allSatisfy { $0.contains("completed") && $0.contains("waiting-response") && $0.contains("keep working in this turn") })
        XCTAssertFalse(element("conversation-user-input-request").exists, "Nudge questions must not become visible answer cards.")
        XCTAssertFalse(app.staticTexts["Which color should I use?"].exists)
        // The recovery turn shows the prompt that carried the answer, as sent, and stores it once.
        XCTAssertTrue(transcriptContains("Question: Which color should I use?"), "The answer's prompt is shown as sent.")
        let reminderPrompts = try XCTUnwrap((try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
            .filter { $0["role"] as? String == "user" }.compactMap { $0["text"] as? String }
            .filter { $0.contains("Answer: Blue") }
        XCTAssertEqual(reminderPrompts.count, 1, "The prompt that applied the answer is stored once.")
        XCTAssertTrue(reminderPrompts.first?.contains("Question: Which color should I use?") == true, "The answer's prompt is stored as sent.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "This is a private Playhouse status nudge."
        )).firstMatch.exists, "Claude's private rejection instructions must not appear in the visible transcript.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse internal outcome nudge:")).firstMatch.exists)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude reminder question", inColumn: "Blocked")
    }
    // case-contract: test_pending_question_repair_restores_thread_owner | A misplaced pending question can be repaired through CLI/XPC only into its owning conversation. Repair rejects a wrong owner and a conflicting destination without mutation, applies both tasks' state atomically, preserves request identity and mode, clears only the misplaced source, and is retryable. Fresh history and the visible UI restore the question only on the original task; answering it clears pending state, and the recovery prompt and response are stored and shown as sent and survive reopening. Retrying an interrupted repair after the destination question was answered rejects the stale source without resurrecting the question.
    func test_pending_question_repair_restores_thread_owner() throws {
        let restartFixture = dataDirectory.appendingPathComponent("codex-fixture-restart-question")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-restart-question"), to: restartFixture)
        codexFixtureExecutable = restartFixture.path
        try "Playhouse test owns this Codex protocol fixture (v1).\n".write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"), atomically: true, encoding: .utf8)
        let target = try XCTUnwrap((try runCLI(["task", "create", "--title", "Repair original question", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])?["id"] as? String)
        let source = try XCTUnwrap((try runCLI(["task", "create", "--title", "Repair misplaced question", "--prompt", "Fixture task description.", "--root", fixture.secondary.path])["result"] as? [String: Any])?["id"] as? String)
        let stranger = try XCTUnwrap((try runCLI(["task", "create", "--title", "Repair wrong destination", "--prompt", "Fixture task description.", "--root", fixture.alternate.path])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", target, "--message", "Ask a restart-safe question.", "--mode", "plan"], expectedStatus: 1)
        let strangerFixture = dataDirectory.appendingPathComponent("codex-fixture-title-success")
        try copyFixtureFile(at: restartFixture, to: strangerFixture)
        _ = try runCLI(["conversation", "send", stranger, "--message", "Start another real conversation."], extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": strangerFixture.path])
        var original = try XCTUnwrap(try conversationState(target))
        let request = try XCTUnwrap(original.removeValue(forKey: "pendingUserInputRequest") as? [String: Any])
        try writeConversationState(target, original)
        let displaced: [String: Any] = ["version": 1, "segments": [], "turns": [], "pendingUserInputRequest": request]
        try writeConversationState(source, displaced)
        let originalState = try XCTUnwrap(try conversationState(target)) as NSDictionary
        let misplacedState = try XCTUnwrap(try conversationState(source)) as NSDictionary
        let wrong = try runCLI(["conversation", "repair-user-input", stranger, "--from-task", source], expectedStatus: 1)
        XCTAssertEqual((wrong["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        XCTAssertEqual(try XCTUnwrap(try conversationState(target)) as NSDictionary, originalState)
        XCTAssertEqual(try XCTUnwrap(try conversationState(source)) as NSDictionary, misplacedState)
        var conflict = request
        conflict["id"] = "a-different-pending-request"
        original["pendingUserInputRequest"] = conflict
        try writeConversationState(target, original)
        let conflictState = try XCTUnwrap(try conversationState(target)) as NSDictionary
        _ = try runCLI(["conversation", "repair-user-input", target, "--from-task", source], expectedStatus: 1)
        XCTAssertEqual(try XCTUnwrap(try conversationState(target)) as NSDictionary, conflictState)
        XCTAssertEqual(try XCTUnwrap(try conversationState(source)) as NSDictionary, misplacedState, "A rejected repair leaves both tasks' state untouched.")
        original.removeValue(forKey: "pendingUserInputRequest")
        try writeConversationState(target, original)
        let repaired = try runCLI(["conversation", "repair-user-input", target, "--from-task", source])
        XCTAssertEqual((repaired["result"] as? [String: Any])?["id"] as? String, request["id"] as? String)
        XCTAssertEqual((repaired["result"] as? [String: Any])?["mode"] as? String, "plan")
        XCTAssertNil(try XCTUnwrap(try conversationState(source))["pendingUserInputRequest"])
        let repairedTarget = try XCTUnwrap(try conversationState(target))
        XCTAssertEqual((repairedTarget["pendingUserInputRequest"] as? [String: Any])?["id"] as? String, request["id"] as? String)
        let receipts = try XCTUnwrap(repairedTarget["userInputRepairs"] as? [[String: Any]])
        XCTAssertEqual(receipts.count, 1, "The destination records a receipt of the repair in the same transaction.")
        XCTAssertEqual(receipts.first?["sourceTaskID"] as? String, source.uppercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("conversation-transcripts").path), "Repairs no longer write JSON transcript backups; SQLite applies both tasks atomically.")
        _ = try runCLI(["conversation", "repair-user-input", target, "--from-task", source])
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Repair misplaced question")
        XCTAssertFalse(element("conversation-user-input-request").exists)
        element("back-to-board-button").click()
        openTask(named: "Repair original question")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        selectQuestionOption(identifier: "ai-question-option-color-Green")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        let recoveryAnswer = "Recovered answer: Green; private token fixture-secret was applied."
        XCTAssertTrue(transcriptMessage(recoveryAnswer).waitToExist(timeout: 15))
        relaunchApp()
        openTask(named: "Repair original question")
        XCTAssertFalse(element("ai-question-form-title").exists)
        XCTAssertTrue(transcriptMessage(recoveryAnswer).waitToExist(timeout: 10), "The recovery response is stored and shown as sent.")
        XCTAssertTrue(transcriptContains("Continue this conversation by applying"), "The prompt that carried the answers is shown as sent.")
        let history = try runCLI(["conversation", "history", target])["result"]
        let historyBytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(history))
        XCTAssertTrue(String(decoding: historyBytes, as: UTF8.self).contains("Answer: fixture-secret"))
        try writeConversationState(source, displaced)
        _ = try runCLI(["conversation", "repair-user-input", target, "--from-task", source], expectedStatus: 1)
        XCTAssertNil(try XCTUnwrap(try conversationState(target))["pendingUserInputRequest"])
    }
    // case-contract: test_codex_questions_can_be_answered_over_cli_xpc | MCP tool/requestUserInput structured questions raised in Plan mode remain in the conversation and move the task to Waiting Response while unanswered; leaving and reopening the conversation preserves the pending question, keyed answers resume the provider turn in In Progress, and the answered turn reports no outcome, so Playhouse drives a private status nudge; when that private turn cannot complete, the task settles in Blocked naming that reason instead of Waiting Response. A parallel conversation retains its own question and thread; the original conversation receives and answers a second question in its original Plan mode, and completing either conversation preserves the other pending request.
    func test_codex_questions_can_be_answered_over_cli_xpc() throws {
        let created = try runCLI(["task", "create", "--title", "Codex questions", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let parallel = try runCLI(["task", "create", "--title", "Another conversation", "--prompt", "Fixture task description.", "--root", fixture.secondary.path])
        let parallelID = try XCTUnwrap((parallel["result"] as? [String: Any])?["id"] as? String)
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-question-isolation-plan-slow").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Codex questions")
        setPlanMode(true)
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()

        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        XCTAssertTrue(element("conversation-user-input-request").exists, "The question should appear inline in the conversation.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !element("ai-question-confirmation-sheet").exists }, timeout: 5))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        assertTaskVisible("Codex questions", inColumn: "Waiting Response")
        attachScreenshot(named: "Pending question remains part of its active conversation")
        openTask(named: "Another conversation")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 5), "A different conversation should open while the question is pending.")
        element("message-composer").click()
        element("message-composer").typeText("Please ask parallel questions.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        let parallelThread = try XCTUnwrap(taskRecord(id: parallelID)?["codexThreadID"] as? String)
        let originalThread = try XCTUnwrap(taskRecord(id: taskID)?["codexThreadID"] as? String)
        XCTAssertNotEqual(parallelThread, originalThread)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        openTask(named: "Codex questions")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 5), "Returning should restore the pending question inline.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertFalse(element("submit-ai-answers-button").isEnabled, "Blank answers must not be submitted.")
        let greenOption = element("ai-question-option-color-Green")
        let blueOption = element("ai-question-option-color-Blue")
        greenOption.click()
        XCTAssertEqual(greenOption.value as? String, "selected")
        XCTAssertEqual(blueOption.value as? String, "not selected")
        blueOption.click()
        XCTAssertEqual(blueOption.value as? String, "selected", "Selecting another option must switch the answer like a radio button instead of adding to it.")
        XCTAssertEqual(greenOption.value as? String, "not selected", "Options must behave as a single-select radio group, not independently toggled checkboxes.")
        let secretAnswer = element("ai-question-answer-token")
        XCTAssertTrue(secretAnswer.exists)
        typeIntoField(secretAnswer, text: "fixture-secret")
        attachScreenshot(named: "Codex structured questions with option and private answer fields")
        element("submit-ai-answers-button").click()

        let resumeDeadline = Date().addingTimeInterval(5)
        var resumedStatus: String?
        while Date() < resumeDeadline {
            resumedStatus = try taskRecord(id: taskID)?["status"] as? String
            if resumedStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(resumedStatus, "In Progress", "The unanswered question must not move the active task out of In Progress.")

        XCTAssertTrue(app.staticTexts["Which color should I use next?"].waitToExist(timeout: 10), "A second question must return to the original task after the other task replaced the shared callback.")
        func pendingQuestion(_ owner: String) throws -> [String: Any] {
            let transcript = try XCTUnwrap(try conversationState(owner))
            return try XCTUnwrap(transcript["pendingUserInputRequest"] as? [String: Any])
        }
        XCTAssertEqual(try pendingQuestion(taskID)["threadID"] as? String, originalThread)
        XCTAssertEqual(try pendingQuestion(taskID)["mode"] as? String, "plan")
        XCTAssertEqual(try pendingQuestion(parallelID)["threadID"] as? String, parallelThread)
        XCTAssertEqual(try pendingQuestion(parallelID)["mode"] as? String, "default")
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()

        let completionDeadline = Date().addingTimeInterval(90)
        var completedStatus: String?
        while Date() < completionDeadline {
            completedStatus = try taskRecord(id: taskID)?["status"] as? String
            if completedStatus == "Blocked" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Blocked", "Without any reported outcome, the submitted answer settles the task in Blocked.")
        XCTAssertTrue(
            (try taskRecord(id: taskID)?["statusMessage"] as? String)?.contains("couldn't run the private turn") == true,
            "The Blocked reason must name why Playhouse stopped driving the work."
        )
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10), "Wait for A's completed provider response before checking B still owns its question.")
        XCTAssertNil(try XCTUnwrap(try conversationState(taskID))["pendingUserInputRequest"])
        XCTAssertFalse(element("ai-question-form-title").exists)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Codex questions", inColumn: "Blocked")
        openTask(named: "Another conversation")
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 5), "Finishing the first task must preserve the parallel question.")
        selectQuestionOption(identifier: "ai-question-option-color-Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        let parallelDeadline = Date().addingTimeInterval(90)
        while Date() < parallelDeadline, try taskRecord(id: parallelID)?["status"] as? String != "Blocked" {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(try taskRecord(id: parallelID)?["status"] as? String, "Blocked")
        XCTAssertTrue(
            (try taskRecord(id: parallelID)?["statusMessage"] as? String)?.contains("couldn't run the private turn") == true,
            "The parallel conversation records the same Blocked reason."
        )
        XCTAssertTrue(waitUntil({ !self.element("ai-question-form-title").exists }, timeout: 10))
        XCTAssertNil(try XCTUnwrap(try conversationState(parallelID))["pendingUserInputRequest"])
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
        element("back-to-board-button").click()
        openTask(named: "Another conversation")
        XCTAssertFalse(element("ai-question-form-title").exists)
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
    }
    // case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section, and the successful retry returns to Waiting Response without an explicit completed outcome.
    func test_codex_empty_question_request_is_rejected() throws {
        let created = try runCLI(["task", "create", "--title", "Empty Codex questions", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let emptyFixture = try makeCodexFixture(emptyQuestions: true).path
        let failedTurn = try runCLI(
            ["conversation", "send", taskID, "--message", "Please ask your questions."],
            expectedStatus: 1,
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": emptyFixture]
        )
        XCTAssertFalse(failedTurn["ok"] as? Bool ?? true)
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Blocked")
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("column-heading-blocked").waitToExist(timeout: 5))
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
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": retryFixture]
        )
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Waiting Response")
        XCTAssertTrue(waitForDisappearance(element("column-heading-blocked")), "The blocked section should disappear after the task is unblocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
        assertTaskVisible("Empty Codex questions", inColumn: "Waiting Response")
    }
}

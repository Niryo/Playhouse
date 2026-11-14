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
        let executable = dataDirectory.appendingPathComponent("claude-fixture-consumed-wake")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        claudeFixtureExecutable = executable.path
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
        XCTAssertTrue(element("pause-response-button").exists,
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
    // case-contract: test_claude_private_recovery_failure_fails_closed | If Claude fails while applying an answer after restart and echoes the answer or recovery instructions, Playhouse returns a generic error, preserves the pending question for retry while the task stays in Waiting Response, and keeps the prompt out of history, saved task state, and diagnostics.
    func test_claude_private_recovery_failure_fails_closed() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-recovery-failure")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        claudeFixtureExecutable = executable.path
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
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Answer: Green")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "private recovery prompt")).firstMatch.exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response",
                       "An unanswered question stays available for retry after a failed recovery attempt.")
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
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Answer: Green")).firstMatch.exists)
    }
    // case-contract: test_codex_pending_question_recovers_after_provider_process_restarts | Codex's pending structured question persists after its provider process exits and leaves the task in Waiting Response while unanswered; Playhouse restores it from fresh CLI/XPC history, keeps provider switching blocked, requires the user to re-enter the secret once, and applies the answers in one recovery turn. The live recovery stream retains safe assistant text while redacting secret echoes; persisted history hides secret recovery responses, provider activities, and file-change diffs. A later non-sensitive Codex turn keeps its own diff and safe response visible in refreshed CLI/UI history while the earlier secret stays absent. In one task, a no-secret recovery response remains visible after a later secret recovery while the secret response is hidden. Secret answers with surrounding whitespace are still redacted when Codex normalizes its echo; the visible UI shows the safe response immediately and after app restart. The first prompt, delivered before the provider exited although its send reported failure, is in history, never returns to the composer, and is not saved as an unsent draft.
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
        XCTAssertTrue(transcriptMessage("Recovered answer: Green; private token [redacted secret answer] was applied.").waitToExist(timeout: 15))
        XCTAssertTrue(transcriptMessage("[Private answer sent after restart]").exists)
        XCTAssertFalse(element("conversation-user-input-request").exists)
        let providerHistory = try String(contentsOf: URL(fileURLWithPath: executable.path + ".history"), encoding: .utf8)
        XCTAssertTrue(providerHistory.contains("Green"))
        XCTAssertTrue(providerHistory.contains("fixture-secret"))
        let immediateActivityDisclosure = element("codex-activity-disclosure")
        // The section is open during a turn and collapsed once it settles; expand only
        // when collapsed, so the redaction check always inspects expanded details.
        XCTAssertTrue(expandActivityDetails(immediateActivityDisclosure),
            "The redaction check must inspect expanded activity details, not a collapsed section.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists,
            "Playhouse conversation content and expanded activity details must redact the re-entered secret.")
        XCTAssertEqual(immediateActivityDisclosure.value as? String, "Expanded, down chevron",
            "The section must still be open, so the redaction check above was not vacuous.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Restart-safe Codex question")
        let persistedHiddenAnswer = transcriptMessage("[Response to private answer hidden]")
        XCTAssertTrue(persistedHiddenAnswer.waitToExist(timeout: 15),
            "After restart, history should hide the assistant response from a secret recovery turn.")
        XCTAssertTrue(transcriptMessage("[Private answer sent after restart]").exists)
        let persistedActivityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(expandActivityDetails(persistedActivityDisclosure),
            "The reloaded redaction check must inspect expanded activity details.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists,
            "The secret must remain redacted from messages, activities, and diffs after Playhouse reloads provider history.")
        XCTAssertEqual(persistedActivityDisclosure.value as? String, "Expanded, down chevron",
            "The reloaded section must still be open, so the redaction check above was not vacuous.")

        let followUpComposer = element("message-composer")
        XCTAssertEqual(followUpComposer.value as? String, "",
            "The delivered first prompt must not come back to the composer after restarts.")
        followUpComposer.click()
        followUpComposer.typeText("Follow up after private recovery.")
        element("send-message-button").click()
        XCTAssertTrue(app.staticTexts["Follow-up after private recovery complete."].waitToExist(timeout: 15),
            "A normal follow-up after private recovery should remain visible in the refreshed conversation.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 30),
            "The follow-up with no reported outcome should finish after two hidden reminders.")
        let followUpHistory = try runCLI(["conversation", "history", taskID])
        let followUpMessages = try XCTUnwrap((followUpHistory["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(followUpMessages.contains { ($0["text"] as? String) == "Follow-up after private recovery complete." },
            "Fresh UI-backed history should retain the safe follow-up response.")
        XCTAssertFalse(followUpMessages.contains { (($0["text"] as? String) ?? "").contains("fixture-secret") },
            "Fresh history after an ordinary turn must not reveal the earlier secret answer.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists,
            "The normal follow-up transcript and its expanded activity must stay free of the earlier secret.")
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Restart-safe Codex question")
        XCTAssertTrue(app.staticTexts["Follow-up after private recovery complete."].waitToExist(timeout: 15),
            "The safe follow-up response should remain visible after reopening provider history.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists,
            "The earlier secret must remain absent after the normal follow-up and another app restart.")

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
        XCTAssertTrue(noSecretAnswer.waitToExist(timeout: 15), "Codex recovery without secret answers should preserve its safe response.")
        XCTAssertFalse(transcriptMessage("[Response to private answer hidden]").exists)
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
        XCTAssertTrue(transcriptMessage("Recovered answer: Green; private token [redacted secret answer] was applied.").waitToExist(timeout: 15))
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Codex recovery without a secret")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        // Earlier rows render only near the viewport, so these checks scan the whole transcript.
        XCTAssertTrue(transcriptScan { self.transcriptMessage("Recovered answer: Blue; no secret was required.").exists },
            "A later secret recovery must leave the earlier safe no-secret response visible after restart.")
        XCTAssertTrue(transcriptScan { self.transcriptMessage("[Response to private answer hidden]").exists },
            "The secret recovery response must remain hidden after restart.")
        assertTranscriptLacks("No row anywhere in the reopened transcript may show the secret.") {
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists
        }
    }
    // case-contract: test_codex_secret_recovery_redaction_fails_closed | When Codex recovery and a later thread-resume/history read error echo the full recovery prompt and answers, Playhouse preserves the pending question while the task stays in Waiting Response, uses a generic visible error, and redacts private content from returned history, saved task state, diagnostics, and error text across fresh CLI/XPC reads and app restarts.
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
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Answer: Green")).firstMatch.exists)
        XCTAssertTrue(element("conversation-user-input-request").exists, "A failed redaction association must leave the question available to retry.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response",
                       "An unanswered question stays available for retry after a failed recovery attempt.")
        XCTAssertFalse((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("fixture-secret"))
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
        XCTAssertTrue(transcriptMessage("[Private answer sent after restart]").exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "fixture-secret")).firstMatch.exists,
            "The failed recovery marker must keep history redacted after app restart.")
        try "Playhouse owns this Codex fixture resume failure marker.\n".write(
            to: URL(fileURLWithPath: executable.path + ".resume-error"),
            atomically: true,
            encoding: .utf8
        )
        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Fail-closed secret recovery")
        let historyError = element("codex-chat-error")
        XCTAssertTrue(historyError.waitToExist(timeout: 15))
        XCTAssertEqual(historyError.label, "History for a private recovery conversation could not be loaded.")
        XCTAssertFalse(historyError.label.contains("fixture-secret"), "A history RPC error must not expose the re-entered secret.")
        XCTAssertTrue(element("conversation-user-input-request").exists, "A history failure must leave the unanswered recovery request visible.")
    }
    // case-contract: test_claude_questions_can_be_answered_after_switching_conversations | Claude AskUserQuestion requests are delivered through the control path and move the task to Waiting Response while pending; the question's Markdown, including a long paragraph, header, and option descriptions reach the client unchanged, and the UI renders the question inline with its Markdown formatted at the reply text size and its long paragraph wrapped in full across several lines without truncation, its header, and each option's description, preserves it across conversation switching, and sends a later answer to Claude before the turn ends in Waiting Response.
    func test_claude_questions_can_be_answered_after_switching_conversations() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-question")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        claudeFixtureExecutable = executable.path
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
    private func exercisePrivateReminderRestart(provider: String) throws {
        let name = provider == "claude" ? "claude-fixture-outcome-reminder-question" : "codex-fixture-private-reminder"
        let executable = dataDirectory.appendingPathComponent(name)
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("\(provider)-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this \(provider == "claude" ? "Claude Code" : "Codex") protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-\(provider)-fixture-owner"), atomically: true, encoding: .utf8)
        if provider == "claude" { claudeFixtureExecutable = executable.path } else { codexFixtureExecutable = executable.path }
        let environment = restartServiceEnvironment()
        let title = "\(provider) private reminder restart"
        let task = try XCTUnwrap(try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        touch(executable.path + ".private-reminder-before")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: title)
        sendFromComposer("Complete this turn.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".private-reminder-before-ready") }, timeout: 30))
        let run = provider == "claude" ? agentManifest(kind: "claude", service: environment) : nil
        if provider == "claude" { app.terminate() }
        try killDaemon(environment: environment)
        touch(executable.path + ".private-reminder-before-release")
        if provider == "claude" {
            let directory = try XCTUnwrap(run?.path.deletingLastPathComponent())
            let output = directory.appendingPathComponent("agent.out")
            var committedOffset: Int?
            XCTAssertTrue(waitUntil({
                guard let bytes = try? Data(contentsOf: output) else { return false }
                var offset = 0
                for line in bytes.split(separator: 10, omittingEmptySubsequences: false) {
                    offset += line.count + 1
                    guard offset <= bytes.count else { break }
                    guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if message["type"] as? String == "control_request", message["request_id"] as? String == "question-request-1" {
                        committedOffset = offset
                        return true
                    }
                }
                return false
            }, timeout: 20))
            let manifestURL = directory.appendingPathComponent("run.json")
            var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            XCTAssertFalse(manifest["writeInProgress"] as? Bool ?? true)
            XCTAssertFalse((manifest["answeredRequestIDs"] as? [String] ?? []).contains("question-request-1"))
            manifest["consumedOffset"] = try XCTUnwrap(committedOffset)
            manifest["pendingRequestIDs"] = Array(Set((manifest["pendingRequestIDs"] as? [String] ?? []) + ["question-request-1"])).sorted()
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".private-reminder-question-rejection"))
            launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
            openTask(named: title)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".private-reminder-question-rejection") }, timeout: 45))
        XCTAssertFalse(element("conversation-user-input-request").exists)
        XCTAssertFalse(app.staticTexts["Which color should I use?"].exists)
        attachScreenshot(named: "\(provider)-reattached-private-question-hidden")
        let history = try runCLI(["conversation", "history", taskID], extraEnvironment: environment)["result"] as? [String: Any]
        XCTAssertNil(history?["pendingUserInputRequest"])
    }

    // case-contract: test_claude_private_reminder_question_after_daemon_restart | A Claude private outcome reminder retains its classification when the daemon restarts: an unanswered question already in the committed provider log is replayed, rejected, never becomes a visible or saved pending question, and stays out of runtime snapshots.
    func test_claude_private_reminder_question_after_daemon_restart() throws {
        try exercisePrivateReminderRestart(provider: "claude")
    }

    // case-contract: test_codex_private_reminder_question_after_daemon_restart | A Codex private outcome reminder retains its classification when the daemon restarts: a question raised by the surviving provider turn is rejected, never becomes a visible or saved pending question, and stays out of runtime snapshots.
    func test_codex_private_reminder_question_after_daemon_restart() throws {
        try exercisePrivateReminderRestart(provider: "codex")
    }

    // case-contract: test_codex_outcome_reminder_rejects_user_questions | A Codex question raised during a private outcome reminder is rejected through the provider protocol, never appears in runtime snapshots or the visible conversation, and leaves no saved pending question; the task settles Blocked with the private-turn failure reason.
    func test_codex_outcome_reminder_rejects_user_questions() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-private-reminder")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"), atomically: true, encoding: .utf8)
        codexFixtureExecutable = executable.path
        let task = try XCTUnwrap(try runCLI(["task", "create", "--title", "Codex reminder question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex"])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        touch(executable.path + ".private-reminder-before")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Codex reminder question")
        sendFromComposer("Complete this turn.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".private-reminder-before-ready") }, timeout: 30))
        XCTAssertFalse(element("conversation-user-input-request").exists)
        touch(executable.path + ".private-reminder-before-release")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".private-reminder-ready") }, timeout: 30))
        var sawPrivateQuestion = false
        XCTAssertTrue(waitUntil({
            if self.element("conversation-user-input-request").exists { sawPrivateQuestion = true }
            return FileManager.default.fileExists(atPath: executable.path + ".private-reminder-question-rejection")
        }, timeout: 30))
        XCTAssertFalse(sawPrivateQuestion, "The private reminder question must stay hidden while it is handled.")
        XCTAssertFalse(element("conversation-user-input-request").exists, "Private questions must never become answer cards.")
        XCTAssertFalse(app.staticTexts["Which color should I use?"].exists)
        attachScreenshot(named: "codex-reminder-private-question-hidden")
        XCTAssertTrue(waitForStatus(taskID, "Blocked", timeout: 30))
        XCTAssertTrue((try taskRecord(id: taskID)?["statusMessage"] as? String)?.contains("couldn't run the private turn") == true)
        XCTAssertNil(try XCTUnwrap(try conversationState(taskID))["pendingUserInputRequest"])
    }

    // case-contract: test_claude_outcome_reminder_rejects_user_questions | A successful Claude turn with an unanswered AskUserQuestion stays In Progress without outcome nudges; after the user answers, the next successful turn receives a hidden CLI status nudge. A question raised during that nudge is rejected through Claude's control protocol with completed, in-progress, and waiting-response instructions, which fails the private turn; both the question and the private rejection instructions stay out of the transcript. Playhouse then stops driving the work and marks the task Blocked naming that reason, rather than spending the remaining nudges.

    func test_claude_outcome_reminder_rejects_user_questions() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-outcome-reminder-question")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        claudeFixtureExecutable = executable.path
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
        attachScreenshot(named: "claude-reminder-ordinary-question")
        attachElementScreenshot(element("conversation-user-input-request"), named: "claude-reminder-ordinary-question-card")
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
        // The answered turn already finished, so the answer may arrive as a recovery turn.
        XCTAssertTrue(waitUntil({
            self.transcriptMessage("Answer received: Blue.").exists || self.transcriptMessage("Recovered answer: Blue.").exists
        }, timeout: 10))
        XCTAssertTrue(waitUntil({ !element("conversation-user-input-request").exists }, timeout: 5))
        touch(executable.path + ".private-reminder-hold")
        element("message-composer").click()
        element("message-composer").typeText("Continue after answering.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".private-reminder-ready") }, timeout: 30))
        XCTAssertFalse(element("conversation-user-input-request").exists, "The private reminder must not show a question while the provider is held.")
        attachScreenshot(named: "claude-reminder-private-question-hidden")
        touch(executable.path + ".private-reminder-release")
        var sawPrivateQuestion = false
        XCTAssertTrue(waitUntil({
            if self.element("conversation-user-input-request").exists { sawPrivateQuestion = true }
            return (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked"
        }, timeout: 60), "A failed private nudge should stop Playhouse driving and settle the task in Blocked.")
        XCTAssertFalse(sawPrivateQuestion, "The private reminder question must stay hidden while it is handled.")
        XCTAssertTrue(
            (try taskRecord(id: taskID)?["statusMessage"] as? String)?.contains("couldn't run the private turn") == true,
            "The Blocked reason must name why Playhouse stopped driving the work."
        )

        XCTAssertTrue(waitUntil({
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let turns = history["turns"] as? [[String: Any]] else { return false }
            return turns.contains { ($0["userText"] as? String)?.contains("Playhouse internal outcome nudge:") == true }
        }, timeout: 10), "The released fixture must finish recording its reminder.")
        let fixtureTurnsData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureTurnsData) as? [String: Any])
        let turns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        let nudges = turns.filter { ($0["userText"] as? String)?.contains("Playhouse internal outcome nudge:") == true }
        XCTAssertEqual(nudges.count, 1, "Rejecting the question fails the private turn, so Playhouse stops driving instead of spending every nudge.")
        XCTAssertTrue(nudges.allSatisfy { ($0["userText"] as? String)?.contains("task outcome command") == true })
        let rejectionText = try String(contentsOfFile: executable.path + ".private-reminder-question-rejection", encoding: .utf8)
        let rejections = rejectionText.split(whereSeparator: \.isNewline)
        XCTAssertEqual(rejections.count, 1)
        XCTAssertTrue(rejections.allSatisfy { $0.contains("completed") && $0.contains("in-progress") && $0.contains("waiting-response") })
        XCTAssertFalse(element("conversation-user-input-request").exists, "Nudge questions must not become visible answer cards.")
        XCTAssertFalse(app.staticTexts["Which color should I use?"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "This is a private Playhouse status nudge."
        )).firstMatch.exists, "Claude's private rejection instructions must not appear in the visible transcript.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse internal outcome nudge:")).firstMatch.exists)
        attachScreenshot(named: "claude-reminder-rejected")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Claude reminder question", inColumn: "Blocked")
    }
    // case-contract: test_pending_question_repair_restores_thread_owner | A misplaced pending question can be repaired through CLI/XPC only into its owning conversation. Repair rejects a wrong owner and a conflicting destination without mutation, applies both tasks' state atomically, preserves request identity and mode, clears only the misplaced source, and is retryable. Fresh history and the visible UI restore the question only on the original task; answering it clears pending state and the safe response survives reopening. Retrying an interrupted repair after the destination question was answered rejects the stale source without resurrecting the question.
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
        XCTAssertTrue(transcriptMessage("Recovered answer: Green; private token [redacted secret answer] was applied.").waitToExist(timeout: 15))
        relaunchApp()
        openTask(named: "Repair original question")
        XCTAssertFalse(element("ai-question-form-title").exists)
        XCTAssertTrue(transcriptMessage("[Response to private answer hidden]").waitToExist(timeout: 10))
        let history = try runCLI(["conversation", "history", target])["result"]
        let historyBytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(history))
        XCTAssertFalse(String(decoding: historyBytes, as: UTF8.self).contains("fixture-secret"))
        XCTAssertFalse(String(decoding: historyBytes, as: UTF8.self).contains("Continue this conversation by applying"))
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
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
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

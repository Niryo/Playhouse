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
    // case-contract: test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary | After a completed Codex fixture turn, switching providers is rejected while a follow-up is queued or a turn is active, and the provider menu is disabled during the turn. A settled switch to Claude records a boundary after the last Codex reply that persists across fresh reads and an app relaunch, keeps the Codex thread, and keeps earlier replies labeled Codex; switching back before any Claude turn removes the empty boundary, and the next Codex turn completes in the same thread.
    func test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary() throws {
        let executablePath = try makeCodexFixture(emptyQuestions: false).path
        codexFixtureExecutable = executablePath
        let claudeExecutable = dataDirectory.appendingPathComponent("claude-fixture-provider-switch")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: claudeExecutable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeExecutable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        claudeFixtureExecutable = claudeExecutable.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Provider switch UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Provider switch UI")
        openTask(named: "Provider switch UI")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(providerMenu.waitToExist(timeout: 10))

        let hold = URL(fileURLWithPath: executablePath + ".outcome-hold")
        let active = URL(fileURLWithPath: executablePath + ".outcome-active")
        let release = URL(fileURLWithPath: executablePath + ".outcome-release")
        try? FileManager.default.removeItem(at: active)
        try? FileManager.default.removeItem(at: release)
        try Data().write(to: hold, options: .atomic)
        defer {
            try? "Release the held fixture turn.\n".write(to: release, atomically: true, encoding: .utf8)
            _ = waitUntil({ !FileManager.default.fileExists(atPath: active.path) }, timeout: 10)
            try? FileManager.default.removeItem(at: hold)
            try? FileManager.default.removeItem(at: active)
            try? FileManager.default.removeItem(at: release)
        }
        element("message-composer").click()
        element("message-composer").typeText("Start with Codex.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: active.path) }, timeout: 10), "The fixture turn should stay active.")
        XCTAssertFalse(providerMenu.isEnabled, "The provider menu is disabled during an active turn.")
        let blockedByTurn = try runCLI(["conversation", "provider", taskID, "set", "claude"], expectedStatus: 1)
        XCTAssertEqual((blockedByTurn["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        XCTAssertTrue(((blockedByTurn["error"] as? [String: Any])?["message"] as? String ?? "").contains("current turn"))
        _ = try runCLI(["task", "outcome", taskID, "completed"])
        try "Release the held fixture turn.\n".write(to: release, atomically: true, encoding: .utf8)
        let codexReply = transcriptMessage("Answers received: Blue / fixture-secret.")
        XCTAssertTrue(codexReply.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 10))
        let codexThread = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)

        let queued = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", "Queued before switching."])["result"] as? [String: Any])
        let blockedByQueue = try runCLI(["conversation", "provider", taskID, "set", "claude"], expectedStatus: 1)
        XCTAssertTrue(((blockedByQueue["error"] as? [String: Any])?["message"] as? String ?? "").contains("queued follow-ups"))
        _ = try runCLI(["conversation", "queue-remove", taskID, try XCTUnwrap(queued["id"] as? String)])

        XCTAssertTrue(waitUntil({ providerMenu.isEnabled }, timeout: 10), "The provider menu is enabled once the turn settles.")
        providerMenu.click()
        let claudeChoice = app.menuItems["conversation-provider-claude"]
        XCTAssertTrue(claudeChoice.waitToExist(timeout: 5))
        claudeChoice.click()
        let boundary = element("provider-boundary-claude")
        XCTAssertTrue(boundary.waitToExist(timeout: 10), "A settled switch shows a provider boundary.")
        XCTAssertEqual(boundary.label, "Conversation switched to Claude")
        XCTAssertGreaterThan(boundary.frame.minY, codexReply.frame.maxY, "The boundary follows the last Codex reply.")
        XCTAssertTrue(app.staticTexts["Codex · Luna"].exists, "Earlier replies stay labeled Codex.")
        let switched = try XCTUnwrap(try taskRecord(id: taskID))
        XCTAssertEqual(switched["conversationProvider"] as? String, "claude")
        XCTAssertEqual(switched["codexThreadID"] as? String, codexThread, "Switching keeps the Codex thread.")

        element("back-to-board-button").click()
        relaunchApp()
        openTask(named: "Provider switch UI")
        XCTAssertTrue(element("provider-boundary-claude").waitToExist(timeout: 10), "The boundary persists across an app relaunch.")
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].exists)

        let reopenedMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ reopenedMenu.isEnabled }, timeout: 10))
        reopenedMenu.click()
        let codexChoice = app.menuItems["conversation-provider-codex"]
        XCTAssertTrue(codexChoice.waitToExist(timeout: 5))
        codexChoice.click()
        XCTAssertTrue(waitForDisappearance(element("provider-boundary-claude"), timeout: 10), "Returning before any Claude turn removes the empty boundary.")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Provider switch UI", prompt: "Continue with Codex.")
        XCTAssertEqual(try taskRecord(id: taskID)?["codexThreadID"] as? String, codexThread, "The next Codex turn completes in the same thread.")
        XCTAssertFalse(element("provider-boundary-claude").exists)
        XCTAssertFalse(transcriptContains("playhouse-handoff-context"))
    }
    // case-contract: test_claude_answer_stays_final_around_outcome_report | Against the Claude Code protocol fixture, the answer Claude writes before running its Playhouse progress and outcome commands and the closing line it adds afterward form one final answer, not commentary, in the streamed final answer, fresh history, and transcript, and the reported outcome moves the task to Review. Text Claude writes before an ordinary tool stays commentary, and a turn that leaves every status nudge unanswered ends in Blocked. The fixture records all five private nudge attempts for each unreported turn; fresh history shows the nudge prompts and their replies. Switching to Codex hands off the whole Claude answer, excludes answered-turn commentary and private nudge prompts and replies including their redacted placeholders, and hands off only the last commentary from the turn that recorded no answer. A new Claude conversation with no explicit model pick dispatches to Sonnet and shows Sonnet as the picker default.
    func test_claude_answer_stays_final_around_outcome_report() throws {
        let claudeExecutable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        let codexExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: claudeExecutable.path), "The prepared Claude Code fixture is missing or not executable.")
        claudeFixtureExecutable = claudeExecutable.path
        codexFixtureExecutable = codexExecutable.path
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: codexExecutable.path + ".history"))
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Claude answer UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Claude answer UI")
        let picker = element("model-picker-menu")
        XCTAssertTrue(waitUntil({ (picker.value as? String)?.contains("Sonnet") == true }, timeout: 10), "A new Claude conversation defaults the picker to Sonnet without an explicit pick.")
        let composer = element("message-composer")
        let story = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
        func send(_ text: String) {
            XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The composer should accept a message.")
            composer.click()
            composer.typeText(text)
            element("send-message-button").click()
        }
        // Transcript messages are labeled groups.
        func visibleTexts(containing text: String) -> XCUIElementQuery {
            app.groups.matching(NSPredicate(format: "label CONTAINS %@", text))
        }
        // The live turn shows every message inline; only once the turn settles does
        // the transcript collapse commentary into Worked for.
        func waitForSettledTurn() {
            XCTAssertTrue(waitUntil({
                self.element("codex-activity-disclosure").exists && self.element("codex-activity-disclosure").label.hasPrefix("Worked for")
                    && !self.element("pause-response-button").exists
            }, timeout: 20), "The turn should settle into its Worked for summary.")
        }

        send("Tell me a very short dog story.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 20), "Claude's reported outcome should move the task to Review.")
        waitForSettledTurn()
        let firstTurnHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: claudeExecutable.path + ".history"))) as? [String: Any])
        let firstTurnArguments = try XCTUnwrap((firstTurnHistory["turns"] as? [[String: Any]])?.first?["arguments"] as? [String])
        let firstTurnModelArgumentIndex = try XCTUnwrap(firstTurnArguments.firstIndex(of: "--model"))
        XCTAssertEqual(firstTurnArguments[firstTurnModelArgumentIndex + 1], "sonnet", "Sending without an explicit pick should dispatch to Sonnet.")
        // Settling re-renders the transcript (commentary folds into Worked for), so the answer can briefly be mid-layout.
        XCTAssertTrue(visibleTexts(containing: story).firstMatch.waitToExist(timeout: 5), "The story should be the visible answer, not collapsed commentary.")
        XCTAssertTrue(visibleTexts(containing: "The story is above.").firstMatch.waitToExist(timeout: 5), "The closing line belongs to the same answer.")
        element("codex-activity-disclosure").click()
        let activityDetails = element("codex-activity-details")
        XCTAssertTrue(activityDetails.waitToExist(timeout: 5), "Worked for should expand.")
        XCTAssertEqual(activityDetails.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", story)).count, 0, "The story must not be inside Worked for.")
        element("codex-activity-disclosure").click()

        send("Please inspect the workspace.")
        XCTAssertTrue(visibleTexts(containing: "Inspection done: the workspace is ready.").firstMatch.waitToExist(timeout: 20))
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked" }, timeout: 60), "A turn that leaves every status nudge unanswered should settle in Blocked.")
        waitForSettledTurn()
        XCTAssertEqual(visibleTexts(containing: "I'll inspect the workspace first.").count, 0, "Text before an ordinary tool stays collapsed commentary.")

        send("Start the checks.")
        XCTAssertTrue(visibleTexts(containing: "Start the checks.").firstMatch.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({
            !self.element("pause-response-button").exists
        }, timeout: 20), "The commentary-only turn should finish.")

        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ providerMenu.isEnabled }, timeout: 10), "The provider menu is enabled once the turn settles.")
        providerMenu.click()
        let codexChoice = app.menuItems["conversation-provider-codex"]
        XCTAssertTrue(codexChoice.waitToExist(timeout: 5))
        codexChoice.click()
        XCTAssertTrue(element("provider-boundary-codex").waitToExist(timeout: 10), "The switch shows a provider boundary.")
        send("Continue the story.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Answers received: Blue / fixture-secret.") }, timeout: 20), "The Codex turn should complete.")
        let claudeHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: claudeExecutable.path + ".history"))) as? [String: Any])
        let claudeTurns = try XCTUnwrap(claudeHistory["turns"] as? [[String: Any]])
        let nudgeTurns = claudeTurns.filter { (($0["userText"] as? String) ?? "").localizedCaseInsensitiveContains("Playhouse internal outcome nudge:") }
        XCTAssertEqual(nudgeTurns.count, 2 * Self.maxOutcomeContinuations, "Both no-outcome turns should receive every private status nudge.")
        let visibleHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let visibleMessages = try XCTUnwrap(visibleHistory["messages"] as? [[String: Any]])
        XCTAssertTrue(visibleMessages.contains { ($0["role"] as? String) == "user" && (($0["text"] as? String) ?? "").localizedCaseInsensitiveContains("Playhouse internal outcome nudge:") }, "Nudges Playhouse sent are shown in history.")
        XCTAssertFalse(visibleMessages.contains { (($0["text"] as? String) ?? "").localizedCaseInsensitiveContains("private outcome reminder hidden") })
        XCTAssertFalse(visibleMessages.contains { (($0["text"] as? String) ?? "").localizedCaseInsensitiveContains("private outcome response hidden") })
        let codexHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: codexExecutable.path + ".history"))) as? [String: Any])
        let handoff = try XCTUnwrap((codexHistory["turns"] as? [[String: Any]])?
            .compactMap { $0["userMessage"] as? String }
            .last { $0.hasSuffix("Continue the story.") }, "The Codex fixture should record this task's handoff turn.")
        XCTAssertTrue(handoff.contains("Claude: \(story)\n\nThe story is above."), "Codex must receive the whole Claude answer: \(handoff)")
        XCTAssertTrue(handoff.contains("Claude: Inspection done: the workspace is ready."))
        XCTAssertFalse(handoff.contains("I'll inspect the workspace first."), "Commentary of an answered turn stays with the provider that produced it.")
        XCTAssertTrue(handoff.contains("Claude: Checks are running; results will follow."), "A turn without an answer hands off its last commentary.")
        XCTAssertFalse(handoff.contains("Starting the checks."), "Only the unanswered turn's last commentary is handed off.")
        XCTAssertFalse(handoff.contains("Playhouse internal outcome nudge:"), "Private status nudges must not cross provider boundaries.")
        XCTAssertFalse(handoff.contains("[Playhouse private outcome reminder hidden]"), "Redacted reminder prompts must not cross provider boundaries.")
        XCTAssertFalse(handoff.contains("private outcome response hidden"), "Redacted reminder replies must not enter handoff context.")
        XCTAssertEqual(visibleTexts(containing: "playhouse-handoff-context").count, 0, "The handoff block stays hidden in the transcript.")

        relaunchApp()
        openTask(named: "Claude answer UI")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        // Earlier turns render only near the viewport, so scroll to each row as a reader would.
        XCTAssertTrue(scrollTranscriptUntilExists(visibleTexts(containing: story).firstMatch), "The saved Claude answer should persist across a relaunch.")
        XCTAssertTrue(scrollTranscriptUntilExists(element("provider-boundary-codex")))
    }
    // case-contract: test_claude_resume_recovers_visible_history | A Claude turn that fails after Claude Code created its session leaves that session in place, and the next turn resumes it instead of claiming the same session ID again. After a Claude turn and Playhouse restart, if Claude cannot find its native resumed session, the retried fresh session receives the prior visible conversation from Playhouse's persisted transcript together with the new prompt. Claude completes the turn, and fresh CLI/XPC history and the visible UI retain both turns. A normal Claude resume continues using the native session without receiving duplicate handoff context.
    func test_claude_resume_recovers_visible_history() throws {
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        let executable = dataDirectory.appendingPathComponent("claude-fixture-resume-recovery")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path), "The prepared Claude Code fixture is missing or not executable.")
        try copyFixtureFile(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let owner = dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        let ownerContents = "Playhouse test owns this Claude Code protocol fixture (v1).\n"
        if FileManager.default.fileExists(atPath: owner.path) {
            XCTAssertEqual(try String(contentsOf: owner, encoding: .utf8), ownerContents)
        } else {
            try Data(ownerContents.utf8).write(to: owner)
        }
        claudeFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude resume recovery UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Claude resume recovery UI")
        let composer = element("message-composer")
        func send(_ text: String) {
            XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The composer should accept a message.")
            composer.click()
            // A prior failed turn restores its text as a pending draft so the user
            // can retry it; clear that before typing the next message.
            composer.typeKey("a", modifierFlags: .command)
            composer.typeText(text)
            element("send-message-button").click()
        }
        let story = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
        let fixtureHistoryURL = URL(fileURLWithPath: executable.path + ".history")

        // A first turn that fails after Claude Code created the session must not
        // leave the conversation unresumable: the retry resumes that session
        // instead of claiming its ID again.
        send("Please fail-this-claude-turn.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Blocked" }, timeout: 20),
                      "A failed Claude turn should move the task to Blocked.")
        XCTAssertTrue((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("Claude Code stopped unexpectedly"),
                      "The Blocked reason should name the provider failure.")
        attachScreenshot(named: "Claude turn failed after its session was created")
        let sessionAfterFailure = try XCTUnwrap(try taskRecord(id: taskID)?["claudeSessionID"] as? String)

        send("Tell me a very short dog story.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(story) }, timeout: 20))
        attachScreenshot(named: "The next turn resumes the session the failed turn left behind")
        let afterFailureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistoryURL)) as? [String: Any])
        let afterFailureTurn = try XCTUnwrap((afterFailureHistory["turns"] as? [[String: Any]])?
            .last { $0["userText"] as? String == "Tell me a very short dog story." })
        XCTAssertTrue(afterFailureTurn["resumed"] as? Bool == true,
                      "A session left behind by a failed turn must be resumed, not claimed again.")
        XCTAssertEqual(afterFailureTurn["sessionID"] as? String, sessionAfterFailure)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 20))
        send("Please inspect the workspace.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Inspection done: the workspace is ready.") }, timeout: 20))
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The normal resumed Claude turn should finish.")
        var fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistoryURL)) as? [String: Any])
        var fixtureTurns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        let normalResume = try XCTUnwrap(fixtureTurns.first { $0["userText"] as? String == "Please inspect the workspace." })
        XCTAssertTrue(normalResume["resumed"] as? Bool == true)
        XCTAssertFalse((normalResume["userText"] as? String ?? "").contains("<playhouse-handoff-context>"))

        relaunchApp()
        openTask(named: "Claude resume recovery UI")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(story) }, timeout: 10), "The first Claude answer should restore from Playhouse's persisted transcript.")
        XCTAssertTrue(transcriptMessage("Please inspect the workspace.").waitToExist(timeout: 10), "The previous user prompt should remain in the reopened transcript.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Inspection done: the workspace is ready.") }, timeout: 10), "The second Claude answer should also restore from Playhouse's persisted transcript.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path + ".missing-resume"))
        try Data("Playhouse test owns this missing-session trigger.\n".utf8).write(to: URL(fileURLWithPath: executable.path + ".missing-resume"))

        send("What happened earlier?")
        // Earlier status nudges already show "OK." replies, so wait for the recovered turn itself.
        XCTAssertTrue(waitUntil({
            guard let history = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistoryURL))) as? [String: Any],
                  let turns = history["turns"] as? [[String: Any]] else { return false }
            return turns.contains { (($0["userText"] as? String) ?? "").hasSuffix("What happened earlier?") }
        }, timeout: 20), "Claude should complete after rebuilding its session from saved history.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 30), "The recovered turn and its status nudges should finish.")
        fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureHistoryURL)) as? [String: Any])
        fixtureTurns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        let recoveredTurn = try XCTUnwrap(fixtureTurns.last { !(($0["userText"] as? String ?? "").localizedCaseInsensitiveContains("Playhouse internal outcome nudge:")) })
        XCTAssertFalse(recoveredTurn["resumed"] as? Bool ?? true, "A missing native session should retry as a new Claude session.")
        let recoveryPrompt = try XCTUnwrap(recoveredTurn["userText"] as? String)
        XCTAssertTrue(recoveryPrompt.contains("<playhouse-handoff-context>"))
        XCTAssertTrue(recoveryPrompt.contains("User: Tell me a very short dog story."))
        XCTAssertTrue(recoveryPrompt.contains("Claude: \(story)"))
        XCTAssertTrue(recoveryPrompt.contains("User: Please inspect the workspace."))
        XCTAssertTrue(recoveryPrompt.contains("Claude: Inspection done: the workspace is ready."))
        XCTAssertTrue(recoveryPrompt.hasSuffix("What happened earlier?"))

        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        let texts = messages.compactMap { $0["text"] as? String }
        XCTAssertTrue(texts.contains("Tell me a very short dog story."))
        XCTAssertTrue(texts.contains("What happened earlier?"))
        XCTAssertTrue(texts.contains("OK."))
    }
}

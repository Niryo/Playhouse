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
    // case-contract: test_conversation_transcript_reopens_from_local_store | Playhouse stores every conversation turn in its own transcript store, for Codex and Claude alike. After a Codex turn and, following a provider switch, a Claude turn, a fresh daemon serves the same messages, roles, texts, providers and order without asking Codex for its thread history: Codex replies stay labeled Codex with the model that wrote them, Claude replies stay labeled Claude, and a limited read returns only the latest page with the count of earlier messages and keeps the Codex-to-Claude boundary after the last Codex message.
    func test_conversation_transcript_reopens_from_local_store() throws {
        let executablePath = try makeCodexFixture(emptyQuestions: false).path
        codexFixtureExecutable = executablePath
        let claudeExecutable = dataDirectory.appendingPathComponent("claude-fixture-local-store")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: claudeExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeExecutable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"), atomically: true, encoding: .utf8
        )
        claudeFixtureExecutable = claudeExecutable.path
        // Its own daemon, so killing it before reopening leaves the UI runner's shared one alone.
        let daemonEnvironment = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).local-store-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemonEnvironment)
        try createTaskFixture(title: "Local transcript UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Local transcript UI")
        openTask(named: "Local transcript UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Local transcript UI", prompt: "Start with Codex.")
        let codexReply = transcriptMessage("Answers received: Blue / fixture-secret.")
        XCTAssertTrue(codexReply.waitToExist(timeout: 10))

        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ providerMenu.isEnabled }, timeout: 10))
        providerMenu.click()
        let claudeChoice = app.menuItems["conversation-provider-claude"]
        XCTAssertTrue(claudeChoice.waitToExist(timeout: 5))
        claudeChoice.click()
        XCTAssertTrue(element("provider-boundary-claude").waitToExist(timeout: 10))
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15))
        composer.click()
        composer.typeText("Tell me a very short dog story.")
        element("send-message-button").click()
        let story = "BISCUIT-7 waited by the gate every evening."
        // A message's group carries its whole text as the label; matching every descendant's
        // value instead snapshots the full tree and can time out in the VM.
        let storyText = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", story)).firstMatch
        XCTAssertTrue(storyText.waitToExist(timeout: 20), "The Claude reply streams into the transcript.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The Claude turn settles.")
        attachScreenshot(named: "Codex and Claude turns in one transcript")
        let before = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let beforeMessages = try XCTUnwrap(before["messages"] as? [[String: Any]])

        // Reopening must come from Playhouse's own store, never from Codex's thread, even in a
        // fresh daemon that has no turn of this conversation in memory.
        let methods = URL(fileURLWithPath: executablePath + ".methods")
        let loggedTurns = (try? String(contentsOf: methods, encoding: .utf8)) ?? ""
        XCTAssertTrue(loggedTurns.split(separator: "\n").contains("turn/start"), "The method log records this case's Codex requests.")
        try Data().write(to: methods, options: .atomic)
        element("back-to-board-button").click()
        let firstPID = try XCTUnwrap(try daemonProcessID(environment: daemonEnvironment))
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before reopening.")
        kill(pid_t(firstPID), SIGKILL)
        XCTAssertTrue(waitUntil({ kill(pid_t(firstPID), 0) != 0 }, timeout: 10), "The daemon that recorded the turns is gone.")
        launchAppWithOpen(environmentOverrides: daemonEnvironment)
        waitForBoardOrAbortSuite()
        openTask(named: "Local transcript UI")
        // A reopened conversation renders from its latest turn; earlier turns render as it scrolls up.
        // The relaunch replaced `app`, so the queries are built again against it.
        let reopenedStory = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", story)).firstMatch
        let reopenedCodexReply = transcriptMessage("Answers received: Blue / fixture-secret.")
        XCTAssertTrue(reopenedStory.waitToExist(timeout: 10), "The Claude reply reopens from the local store.")
        let claudeReplyID = try XCTUnwrap(beforeMessages.last { $0["role"] as? String == "assistant" && $0["provider"] as? String == "claude" }?["id"] as? String)
        let claudeLabel = element("assistant-provider-\(claudeReplyID)")
        XCTAssertTrue(claudeLabel.waitToExist(timeout: 5))
        XCTAssertTrue((claudeLabel.value as? String)?.hasPrefix("Claude") == true, "The Claude reply keeps its provider label.")
        attachElementScreenshot(claudeLabel, named: "Reopened Claude reply keeps its provider label")
        XCTAssertTrue(scrollTranscriptUntilExists(reopenedCodexReply), "The Codex reply reopens from the local store.")
        let codexReplyID = try XCTUnwrap(beforeMessages.last { $0["role"] as? String == "assistant" && $0["provider"] as? String == "codex" }?["id"] as? String)
        let codexLabel = element("assistant-provider-\(codexReplyID)")
        XCTAssertEqual(codexLabel.value as? String, "Codex · Luna", "The Codex reply keeps its provider and model label.")
        let boundary = element("provider-boundary-claude")
        XCTAssertTrue(boundary.exists, "The provider boundary reopens between the turns.")
        XCTAssertLessThan(reopenedCodexReply.frame.maxY, boundary.frame.minY, "The boundary follows the Codex turn.")
        XCTAssertTrue(reopenedStory.exists, "Scrolling up keeps the Claude turn rendered below.")
        XCTAssertLessThan(boundary.frame.maxY, reopenedStory.frame.minY, "The Codex turn stays before the Claude turn.")
        attachScreenshot(named: "Transcript reopened from the local store after relaunch")
        attachElementScreenshot(codexLabel, named: "Reopened Codex reply keeps its model label")

        let secondPID = try XCTUnwrap(try daemonProcessID(environment: daemonEnvironment))
        XCTAssertNotEqual(secondPID, firstPID, "A fresh daemon serves the reopened conversation.")
        let after = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let afterMessages = try XCTUnwrap(after["messages"] as? [[String: Any]])
        func summary(_ messages: [[String: Any]]) -> [String] {
            messages.map { "\($0["id"] ?? "")|\($0["role"] ?? "")|\($0["provider"] ?? "")|\($0["modelID"] ?? "")|\($0["text"] ?? "")" }
        }
        XCTAssertEqual(summary(afterMessages), summary(beforeMessages), "The reopened transcript is unchanged.")
        XCTAssertTrue(beforeMessages.contains { $0["role"] as? String == "assistant" && $0["provider"] as? String == "codex" && ($0["modelID"] as? String)?.isEmpty == false })
        let page = try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "2"])["result"] as? [String: Any])
        XCTAssertEqual(summary(try XCTUnwrap(page["messages"] as? [[String: Any]])), Array(summary(beforeMessages).suffix(2)))
        XCTAssertEqual(page["earlierMessageCount"] as? Int, beforeMessages.count - 2)
        let lastCodexMessageID = try XCTUnwrap(beforeMessages.last { $0["provider"] as? String == "codex" }?["id"] as? String)
        func boundaries(_ history: [String: Any]) -> [String] {
            ((history["providerBoundaries"] as? [[String: Any]]) ?? []).map { "\($0["provider"] ?? "")|\($0["afterMessageID"] ?? "")" }
        }
        XCTAssertEqual(boundaries(after), ["claude|\(lastCodexMessageID)"])
        XCTAssertEqual(boundaries(page), ["claude|\(lastCodexMessageID)"], "A limited read keeps the Codex-to-Claude boundary after the last Codex message.")
        let requested = (try? String(contentsOf: methods, encoding: .utf8)) ?? ""
        for method in ["thread/read", "thread/turns/list", "thread/items/list"] {
            XCTAssertFalse(requested.split(separator: "\n").contains(Substring(method)), "Reopening never asks Codex for its thread history.")
        }
    }
    // case-contract: test_claude_answer_stays_final_around_outcome_report | Against the Claude Code protocol fixture, the answer Claude writes before running its Playhouse progress and outcome commands and the closing line it adds afterward form one final answer, not commentary, in the streamed final answer, fresh history, and transcript, and the reported outcome moves the task to Review. Text Claude writes before an ordinary tool stays commentary, and a turn that leaves every status nudge unanswered ends in Blocked. The fixture records the single private recovery prompt for each unreported turn; fresh history shows the nudge prompts and their replies. Switching to Codex hands off the whole Claude answer, excludes answered-turn commentary and private nudge prompts and replies including their redacted placeholders, and hands off only the last commentary from the turn that recorded no answer. A new Claude conversation with no explicit model pick dispatches to Sonnet and shows Sonnet as the picker default.
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
        XCTAssertEqual(nudgeTurns.count, 2 * Self.outcomeRecoveryPrompts, "Each no-outcome turn should receive exactly one private recovery prompt.")
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
    // case-contract: test_codex_resume_recovers_visible_history | After a Codex turn and a provider restart, a normal Codex send resumes the saved thread without handoff context. If Codex then reports that it no longer has the thread, Playhouse starts a new Codex thread, saves its ID on the task, and sends the prior visible conversation from Playhouse's persisted transcript together with the new prompt; Codex completes the turn, the replacement is recorded in diagnostics, the next send continues on the new thread without handoff context, and fresh CLI/XPC history and the visible UI retain every turn.
    func test_codex_resume_recovers_visible_history() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-resume-recovery")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8).write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        let title = "Codex resume recovery UI"
        try createTaskFixture(title: title, roots: [fixture.primary.path])
        let taskID = try taskID(named: title)
        let turnStartsURL = URL(fileURLWithPath: executable.path + ".turn-starts")
        let reply = "Answers received: Blue / fixture-secret."
        func lastTurnStart(endingWith message: String) throws -> [String: Any] {
            let lines = try String(contentsOf: turnStartsURL, encoding: .utf8).split(separator: "\n")
            let starts = try lines.map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            return try XCTUnwrap(starts.last { ($0["text"] as? String ?? "").hasSuffix(message) }, "Codex never started a turn for \(message).")
        }
        func codexThreadID() throws -> String {
            try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        }

        openTask(named: title)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: title, prompt: "Start with Codex.")
        let originalThread = try codexThreadID()

        // A working resume after a restart keeps the thread and sends no transcript.
        try restartProvider(executable)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: title, prompt: "Continue normally.")
        let normal = try lastTurnStart(endingWith: "Continue normally.")
        XCTAssertEqual(normal["threadId"] as? String, originalThread)
        XCTAssertEqual(normal["text"] as? String, "Continue normally.", "A working resume must not receive duplicate transcript context.")

        // Codex loses the thread while Playhouse is closed; the reopened conversation still shows it.
        let missing = URL(fileURLWithPath: executable.path + ".missing-thread")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try restartProvider(executable)
        relaunchApp()
        openTask(named: title)
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        XCTAssertTrue(scrollTranscriptUntilExists(transcriptMessage("Start with Codex.")), "The first prompt should restore from Playhouse's persisted transcript.")
        XCTAssertTrue(scrollTranscriptUntilExists(transcriptMessage("Continue normally.")), "The second prompt should restore from Playhouse's persisted transcript.")
        attachScreenshot(named: "Codex conversation reopened before its thread went missing")
        // Armed only now, so the send's resume is the one that finds the thread gone.
        try Data("Playhouse test owns this missing-thread trigger.\n".utf8).write(to: missing)

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title, prompt: "What happened earlier?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Codex should have been asked to resume the missing thread.")
        let replacement = try codexThreadID()
        XCTAssertNotEqual(replacement, originalThread, "A missing thread is replaced by a new one saved on the task.")
        let recovered = try lastTurnStart(endingWith: "What happened earlier?")
        XCTAssertEqual(recovered["threadId"] as? String, replacement)
        let recoveryPrompt = try XCTUnwrap(recovered["text"] as? String)
        XCTAssertTrue(recoveryPrompt.contains("<playhouse-handoff-context>"))
        XCTAssertTrue(recoveryPrompt.contains("User: Start with Codex."))
        XCTAssertTrue(recoveryPrompt.contains("User: Continue normally."))
        XCTAssertTrue(recoveryPrompt.contains("Codex: \(reply)"))
        XCTAssertFalse(recoveryPrompt.contains("User: What happened earlier?"), "The new prompt is not repeated inside its own context.")
        XCTAssertTrue(recoveryPrompt.hasSuffix("What happened earlier?"))
        let replaced = try diagnosticEvents().filter {
            $0["event"] as? String == "conversation.thread.replaced_missing" && $0["taskID"] as? String == taskID
        }
        XCTAssertEqual(replaced.map { [$0["provider"] as? String, $0["missingThreadID"] as? String, $0["threadID"] as? String] },
                       [["codex", originalThread, replacement]])
        XCTAssertTrue(transcriptMessage("What happened earlier?").waitToExist(timeout: 10), "The transcript shows the user's own prompt.")
        XCTAssertFalse(transcriptContains("<playhouse-handoff-context>"), "The transcript does not show the context sent with it.")
        attachScreenshot(named: "Codex thread replaced after it went missing")

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title, prompt: "And after that?")
        let following = try lastTurnStart(endingWith: "And after that?")
        XCTAssertEqual(following["threadId"] as? String, replacement)
        XCTAssertEqual(following["text"] as? String, "And after that?", "The replacement thread already has the conversation.")

        relaunchApp()
        openTask(named: title)
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        for prompt in ["Start with Codex.", "Continue normally.", "What happened earlier?", "And after that?"] {
            XCTAssertTrue(scrollTranscriptUntilExists(transcriptMessage(prompt)), "\(prompt) should remain in the reopened transcript.")
        }
        attachScreenshot(named: "Every turn remains after the replaced thread continues")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        let userTexts = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["text"] as? String }
        for prompt in ["Start with Codex.", "Continue normally.", "What happened earlier?", "And after that?"] {
            XCTAssertTrue(userTexts.contains(prompt), "\(prompt) should persist in fresh CLI/XPC history.")
        }
        XCTAssertFalse(userTexts.contains { $0.contains("<playhouse-handoff-context>") })
        XCTAssertEqual(messages.filter { $0["role"] as? String == "assistant" && $0["text"] as? String == reply }.count, 4)
    }
    // case-contract: test_codex_standalone_chat_resume_recovers_page_history | A Codex standalone chat page keeps its own thread: after a provider restart, a send on the page resumes that thread without page context. If Codex then reports that it no longer has the page's thread, Playhouse starts a new Codex thread, saves it as the page's provider session, and sends only that page's turns from Playhouse's stored chat pages as context together with the new prompt, never an earlier page's turns or the new prompt itself; the replacement is recorded in diagnostics, the next send on the page continues on the new thread without context, and the page keeps every turn in fresh CLI/XPC reads and the visible chat.
    func test_codex_standalone_chat_resume_recovers_page_history() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat(provider: "codex")
        func activePage() throws -> [String: Any] {
            try XCTUnwrap(restartChatStatus(environment)?["activePage"] as? [String: Any])
        }
        func send(_ text: String, newTitle: String? = nil) throws -> [String: Any] {
            _ = sendFiledRestartChatTurn(executable, text, newTitle: newTitle, environment: environment)
            let ready = try String(contentsOfFile: executable + ".reattach-ready", encoding: .utf8)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ready.utf8)) as? [String: Any])
        }

        _ = try send("Name a moon of Mars.")
        let earlierPageID = try XCTUnwrap(try activePage()["id"] as? String)
        _ = try send("Tell me about volcanoes.", newTitle: "Volcanoes")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Volcanoes") }, timeout: 20))
        let pageID = try XCTUnwrap(try activePage()["id"] as? String)
        XCTAssertNotEqual(pageID, earlierPageID)
        let seeded = try send("What about lava?")
        let pageThread = try XCTUnwrap(try activePage()["providerSessionID"] as? String)
        XCTAssertEqual(seeded["threadId"] as? String, pageThread, "The page's first turn starts the page's own thread.")

        // A working resume after a restart keeps the page's thread and sends no page context.
        let serverBefore = agentManifest(kind: "codex", service: environment)?.manifest["process"] as? NSDictionary
        XCTAssertNotNil(serverBefore, "The chat's turns run on a shared Codex app-server.")
        try restartProvider(URL(fileURLWithPath: executable))
        let normal = try send("Continue normally.")
        let serverAfter = try XCTUnwrap(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? NSDictionary)
        XCTAssertNotEqual(serverAfter, serverBefore,
                          "The send after a provider restart runs on a new app-server, which has to resume the page's thread.")
        XCTAssertEqual(normal["threadId"] as? String, pageThread)
        XCTAssertFalse((normal["text"] as? String ?? "").contains("<playhouse-handoff-context>"), "A working resume must not receive the page again.")

        try restartProvider(URL(fileURLWithPath: executable))
        let missing = executable + ".missing-thread"
        try Data("Playhouse test owns this missing-thread trigger.\n".utf8).write(to: URL(fileURLWithPath: missing))
        let recovered = try send("What happened earlier?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "Codex should have been asked to resume the page's missing thread.")
        let replacement = try activePage()
        XCTAssertEqual(replacement["id"] as? String, pageID)
        let replacementThread = try XCTUnwrap(replacement["providerSessionID"] as? String)
        XCTAssertNotEqual(replacementThread, pageThread, "The page's missing thread is replaced by a new one saved on the page.")
        XCTAssertEqual(recovered["threadId"] as? String, replacementThread)
        let prompt = try XCTUnwrap(recovered["text"] as? String)
        XCTAssertTrue(prompt.contains("<playhouse-handoff-context>"))
        for earlier in ["Tell me about volcanoes.", "What about lava?", "Continue normally.", "After restart."] {
            XCTAssertTrue(prompt.contains(earlier), "The new thread receives the page's own turn \(earlier).")
        }
        XCTAssertFalse(prompt.contains("Name a moon of Mars."), "An earlier page's turns never reach this page's thread.")
        XCTAssertFalse(prompt.contains("User: What happened earlier?"), "The new prompt is not repeated inside its own context.")
        XCTAssertTrue(prompt.hasSuffix("What happened earlier?"))
        let replaced = try diagnosticEvents().filter {
            $0["event"] as? String == "conversation.thread.replaced_missing" && $0["taskID"] as? String == chatID
        }
        XCTAssertEqual(replaced.map { [$0["provider"] as? String, $0["missingThreadID"] as? String, $0["threadID"] as? String] },
                       [["codex", pageThread, replacementThread]])
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows("What happened earlier?", after: "Continue normally.") }, timeout: 20),
                      "The chat shows the user's own prompt under its page's earlier turns.")
        XCTAssertFalse(transcriptContains("<playhouse-handoff-context>"), "The chat does not show the context sent with it.")
        attachScreenshot(named: "Codex chat page thread replaced after it went missing")

        let following = try send("And after that?")
        XCTAssertEqual(following["threadId"] as? String, replacementThread)
        XCTAssertFalse((following["text"] as? String ?? "").contains("<playhouse-handoff-context>"), "The replacement thread already has the page.")
        XCTAssertEqual(
            restartChatPageTexts(pageID, environment: environment).filter { $0 != "Before restart." && $0 != "After restart." },
            ["Tell me about volcanoes.", "What about lava?", "Continue normally.", "What happened earlier?", "And after that?"],
            "The page keeps every turn, with the user's own prompts."
        )
        XCTAssertEqual(restartChatPageTexts(earlierPageID, environment: environment), ["Name a moon of Mars.", "Before restart.", "After restart."])

        XCTAssertTrue(terminateAppAndWait(app))
        launchApp(defaultParent: nil, environmentOverrides: environment)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        // The relaunched chat opens on its newest turn; earlier turns load as the reader scrolls up.
        XCTAssertTrue(waitUntil({ self.transcriptMessage("And after that?").exists }, timeout: 20))
        for (prompt, earlier) in [("What happened earlier?", "Continue normally."), ("And after that?", "What happened earlier?")] {
            XCTAssertTrue(transcriptScan { self.chatTranscriptShows(prompt, after: earlier) },
                          "\(prompt) should remain under its page after a relaunch.")
        }
        attachScreenshot(named: "Codex chat page keeps every turn after a relaunch")
    }

    // case-contract: test_standalone_chat_page_anchors_jump_and_recall | The standalone chat's pages can be read one at a time: `conversation history --page <page-id> --limit N` returns the window that starts at that page's first message, with earlierMessageCount and laterMessageCount telling how much of the chat lies before and after it, and `--after <message-id>` continues the window forward, so jumping to an old page reads only that page's window rather than every page around it. The windows match the same slices of the full history; an unknown page or message is not_found, combining --before, --after and --page is invalid_argument, and --page on a board task is invalid_argument. In the chat, a compact column of page labels left of the transcript, centered on its height, lists the pages by title (long titles truncated), newest at the bottom, at most 15 in view at a time with no scroll bar, reading older labels only as the column is scrolled up; clicking a label shows that page from its first message with only its window loaded (the transcript reports Showing earlier), scrolling down loads the following messages, the label of the page at the top of the transcript is marked current, and Latest returns to the newest messages, as does the Jump to bottom arrow centered below the labels, from an earlier page or after scrolling up the newest messages, at once and without the labels moving off the transcript's middle. Unlocked, which is the default, the labels are folded into a long thin handle at the transcript's leading edge halfway down it, and the messages keep their width: hovering the handle slides the labels out and pushes the messages right, they stay out as the pointer moves from the handle onto them, and moving the pointer off them folds them back in, once, even when the pointer rests beside them where the folding labels pass. The handle stays beside the open labels, thicker, under a small open lock icon that is absent while they are folded, and clicking it locks them open after the pointer leaves, closing the lock while the handle keeps its color, which persists across a relaunch; clicking it again unlocks them, opening the lock, so they fold back into the handle when the pointer leaves; agent replies end at the same right edge as the user's messages. A page separator's Recall button, with a hint that it references that conversation, returns to the bottom of the chat and shows Recalling <title> in the composer; the next message carries that page into the turn through the provider-neutral context-page seeding (the CLI's --context-page), and the indication can be removed and clears after sending. Page windows, labels and recall are Playhouse-owned and shared by Claude and Codex, so one representative provider (Claude) covers the case.
    func test_standalone_chat_page_anchors_jump_and_recall() throws {
        executionTimeAllowance = 360 // It walks 45 pages: jumps, Latest, Jump to bottom, recall, a turn and a relaunch.
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-page-anchors")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)

        // Forty-two short pages, then three long ones: more pages than the labels read at
        // once, and more messages than the transcript loads at once.
        let longTitle = "Deep ocean currents and the thermohaline circulation"
        let topics = (1...42).map { (String(format: "Topic %02d", $0), 1) } + [(longTitle, 19), ("Glaciers", 19), ("Harbor", 19)]
        for (title, replies) in topics {
            _ = try runCLI(["conversation", "send", chatID, "--message", "anchor-page:\(title.replacingOccurrences(of: " ", with: "-")):\(replies)"])
        }
        let listed = try XCTUnwrap((try runCLI(["chat", "page", "list", "--limit", "100"])["result"] as? [String: Any])?["pages"] as? [[String: Any]])
        var pageIDs: [String: String] = [:]
        for page in listed where (page["messageCount"] as? Int ?? 0) > 0 {
            pageIDs[try XCTUnwrap(page["title"] as? String)] = try XCTUnwrap(page["id"] as? String)
        }
        XCTAssertEqual(pageIDs.count, 45, "Each turn opens its own titled page.")

        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        waitForConversationLoad()

        let scrollView = element("conversation-scroll-view")
        let anchors = app.scrollViews.matching(identifier: "chat-page-anchors").firstMatch
        func label(_ title: String) -> XCUIElement { element("chat-page-anchor-\(pageIDs[title] ?? "missing")") }
        func transcriptValue() -> String { scrollView.value as? String ?? "" }
        func renderedCount() -> Int { transcriptValue().split(separator: " ").compactMap { Int($0) }.first ?? 0 }
        func currentLabelTitle() -> String? {
            let current = anchors.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "chat-page-anchor-", "current"))
            return current.count == 1 ? current.firstMatch.label : nil
        }
        func separatorTop(_ title: String) -> CGFloat? {
            chatPageSeparators(title).first.map { $0.minY - scrollView.frame.minY }
        }
        /// Scrolls the labels until `title`'s label can be clicked.
        func revealLabel(_ title: String) -> Bool {
            let target = label(title)
            func ready() -> Bool { target.exists && target.isHittable && anchors.frame.contains(target.frame) }
            for delta: CGFloat in [150, -150] {
                for _ in 0..<40 where !ready() {
                    anchors.scroll(byDeltaX: 0, deltaY: delta)
                    _ = waitUntil(ready, timeout: 0.3)
                }
            }
            return ready()
        }
        func jump(to title: String) {
            XCTAssertTrue(revealLabel(title), "The label for \(title) should be reachable by scrolling the labels.")
            label(title).click()
            XCTAssertTrue(waitUntil({ (separatorTop(title) ?? 1_000) < 80 && currentLabelTitle() == title }, timeout: 15),
                          "Clicking \(title)'s label should show that page from its first message; transcript=\(transcriptValue()), separator=\(String(describing: separatorTop(title))), current=\(String(describing: currentLabelTitle())).")
        }

        let wideReply = scrollView.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "assistant-message-", "Harbor reply 19.")).firstMatch
        func moveOffLabels() {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).hover()
        }
        // The most saturated pixel across the middle of the handle's line: near zero for a gray
        // line, high for one in the accent color.
        func lineSaturation(of handle: XCUIElement) -> CGFloat {
            guard let image = handle.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var saturation: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in (bitmap.pixelsHigh / 2 - 4)...(bitmap.pixelsHigh / 2 + 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    saturation = max(saturation, channels.max()! - channels.min()!)
                }
            }
            return saturation
        }

        // Unlocked by default, the labels fold into a thin handle halfway down the transcript's
        // leading edge, and the messages keep their width.
        let handle = element("chat-page-anchors-handle")
        let lock = element("chat-page-anchors-lock")
        XCTAssertTrue(handle.waitToExist(timeout: 10), "The chat offers its pages behind a handle at the transcript's edge.")
        XCTAssertFalse(lock.exists, "The folded handle shows no lock.")
        XCTAssertFalse(anchors.exists, "Unlocked labels stay folded until the handle is hovered.")
        XCTAssertEqual(handle.value as? String, "folded")
        XCTAssertLessThanOrEqual(handle.frame.width, 20, "The handle is thin.")
        XCTAssertEqual(handle.frame.height, 108, accuracy: 2, "The handle is a long target.")
        XCTAssertLessThan(handle.frame.minX - scrollView.frame.minX, 40, "The handle sits at the transcript's leading edge.")
        XCTAssertEqual(handle.frame.midY, scrollView.frame.midY, accuracy: 4, "The handle sits halfway down the transcript.")
        XCTAssertTrue(scrollTranscriptUntilExists(wideReply), "The newest page's last reply should be reachable.")
        let foldedReplyLeft = wideReply.frame.minX
        attachScreenshot(named: "chat-page-anchors-folded-into-handle")
        attachElementScreenshot(handle, named: "chat-page-anchors-handle-folded-closeup")

        // Hovering the handle slides the labels out beside it and pushes the messages right; the
        // handle stays, thicker, as the way to lock them. Leaving folds them.
        handle.hover()
        XCTAssertTrue(waitUntil({ anchors.exists && wideReply.frame.minX > foldedReplyLeft + 60 }, timeout: 5),
                      "Hovering the handle slides the labels out and pushes the messages right; reply left \(foldedReplyLeft) then \(wideReply.frame.minX).")
        XCTAssertGreaterThan(wideReply.frame.minX, anchors.frame.maxX, "The pushed messages start right of the labels.")
        XCTAssertTrue(handle.exists, "The handle stays beside the open labels.")
        XCTAssertEqual(handle.value as? String, "open")
        XCTAssertEqual(handle.label, "Lock chat pages open")
        XCTAssertLessThanOrEqual(handle.frame.maxX, anchors.frame.minX + 1, "The handle sits left of the labels.")
        XCTAssertEqual(handle.frame.midY, anchors.frame.midY, accuracy: 4, "The handle stays centered on the labels.")
        XCTAssertTrue(lock.waitToExist(timeout: 2), "A lock shows above the handle beside the open labels.")
        XCTAssertEqual(lock.value as? String, "unlocked", "The lock shows open while the labels are unlocked.")
        XCTAssertLessThanOrEqual(lock.frame.maxY, handle.frame.midY - 32, "The lock sits above the handle's line.")
        XCTAssertGreaterThanOrEqual(lock.frame.minY, handle.frame.minY - 1, "The lock sits inside the handle's target.")
        XCTAssertEqual(lock.frame.midX, handle.frame.midX, accuracy: 3, "The lock is centered over the handle.")
        XCTAssertEqual(element("chat-page-anchors-pin").exists, false, "The handle alone locks the labels; there is no separate pin.")
        _ = waitUntil({ false }, timeout: 0.6)
        XCTAssertTrue(anchors.exists && handle.value as? String == "open", "Labels slid out under a still pointer stay open past the collapse grace.")
        attachScreenshot(named: "chat-page-anchors-revealed-from-handle")
        attachElementScreenshot(handle, named: "chat-page-anchors-handle-open-closeup")
        // Crossing from the handle onto the labels keeps them out, past the collapse grace.
        anchors.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        _ = waitUntil({ false }, timeout: 0.6)
        XCTAssertTrue(anchors.exists && handle.value as? String == "open", "Labels stay open while the pointer moves from the handle onto them.")
        // Folding, the labels slide left across the strip beside them; a pointer resting there, off
        // the open labels, lets them fold without catching them and bringing them back out, over and over.
        XCTAssertLessThan(anchors.frame.minY + 12, handle.frame.minY, "The labels reach above the handle.")
        let windowFrame = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: handle.frame.midX - windowFrame.minX, dy: anchors.frame.minY + 12 - windowFrame.minY))
            .hover()
        var foldStates: [String] = []
        let foldStart = Date()
        while Date().timeIntervalSince(foldStart) < 3 {
            let value = handle.value as? String ?? "?"
            if foldStates.last != value { foldStates.append(value) }
        }
        XCTAssertEqual(Array(foldStates.drop(while: { $0 == "open" })), ["folded"],
                       "Labels left with the pointer beside them fold once and stay folded; states \(foldStates).")
        XCTAssertFalse(anchors.exists, "The folded labels stay folded.")
        handle.hover()
        XCTAssertTrue(waitUntil({ anchors.exists && handle.value as? String == "open" }, timeout: 5))
        anchors.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        moveOffLabels()
        XCTAssertTrue(waitUntil({ !anchors.exists && handle.value as? String == "folded" && abs(wideReply.frame.minX - foldedReplyLeft) < 2 }, timeout: 5),
                      "Moving the pointer off the labels folds them back and gives the messages their width back; reply left \(wideReply.frame.minX).")

        // Clicking the handle locks the labels open after the pointer leaves, and closes the lock above it.
        handle.hover()
        XCTAssertTrue(waitUntil({ anchors.exists && handle.value as? String == "open" }, timeout: 5))
        handle.click()
        XCTAssertTrue(waitUntil({ handle.value as? String == "locked" }, timeout: 5), "Clicking the handle locks the labels open.")
        XCTAssertEqual(handle.label, "Unlock chat pages")
        moveOffLabels()
        XCTAssertFalse(waitUntil({ !anchors.exists }, timeout: 1.5), "Locked labels stay open after the pointer leaves them.")
        XCTAssertEqual(handle.value as? String, "locked", "The handle stays, marked locked, beside the locked labels.")
        XCTAssertEqual(lock.value as? String, "locked", "The lock above the handle closes when the labels are locked.")
        XCTAssertLessThan(lineSaturation(of: handle), 0.12, "The locked handle keeps its gray line; the lock alone marks it locked.")
        attachScreenshot(named: "chat-page-anchors-locked-open")
        attachElementScreenshot(handle, named: "chat-page-anchors-handle-locked-closeup")

        // The labels sit left of the transcript: newest pages only, compact, long titles cut.
        XCTAssertTrue(anchors.waitToExist(timeout: 10), "The chat shows its page labels beside the transcript.")
        XCTAssertEqual(anchors.value as? String, "40 pages, older pages above", "Only the newest pages' labels are read at first.")
        // The newest turn's 18 earlier replies fold into its Worked for row, leaving 126 of the 144.
        XCTAssertTrue(waitUntil({ transcriptValue().hasPrefix("Showing latest ") && transcriptValue().hasSuffix(" of 126 messages") }, timeout: 10), transcriptValue())
        XCTAssertTrue(waitUntil({ label("Harbor").exists && label(longTitle).exists }, timeout: 5), "The newest pages' labels are in view.")
        XCTAssertEqual(label("Harbor").label, "Harbor", "A label is its page's title.")
        XCTAssertEqual(label(longTitle).label, longTitle)
        XCTAssertLessThanOrEqual(anchors.frame.width, 130, "The labels stay compact.")
        XCTAssertGreaterThanOrEqual(anchors.frame.width, 100, "The labels have room for a short title.")
        // A window tall enough that the 15 labels, not the transcript's height, bound the column.
        let window = app.windows.firstMatch
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: -2))
        bottomEdge.press(forDuration: 0.2, thenDragTo: bottomEdge.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertTrue(waitUntil({ scrollView.frame.height >= 452 }, timeout: 5),
                      "The window should grow until the transcript has room for more than 15 labels; transcript height \(scrollView.frame.height).")
        XCTAssertEqual(anchors.frame.midY, scrollView.frame.midY, accuracy: 4, "The labels sit halfway down the transcript.")
        let labelsInView = anchors.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-page-anchor-"))
            .allElementsBoundByIndex.filter { anchors.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
        XCTAssertEqual(labelsInView, 15, "Exactly the 15 newest labels are in view.")
        XCTAssertEqual(anchors.frame.height, 390, accuracy: 3, "The column is as tall as 15 labels.")
        XCTAssertLessThan(anchors.frame.height, scrollView.frame.height - 52 - 8, "The column stops at 15 labels with transcript height to spare.")
        XCTAssertEqual(anchors.scrollBars.count, 0, "The labels scroll without a scroll bar.")
        XCTAssertLessThanOrEqual(label(longTitle).frame.maxX, anchors.frame.maxX + 1, "A long title is cut to the labels' width instead of running under the messages.")
        XCTAssertEqual(label(longTitle).frame.height, label("Harbor").frame.height, accuracy: 1, "A long title stays on one line, cut with an ellipsis.")
        XCTAssertGreaterThan(label("Harbor").frame.minY - label("Glaciers").frame.maxY, 10, "Labels are set apart from each other, newest lowest.")
        XCTAssertFalse(label("Topic 03").exists, "An older page has no label until the labels are scrolled up to it.")
        XCTAssertTrue(waitUntil({ currentLabelTitle() == "Harbor" }, timeout: 10), "The label of the page in view is marked; current=\(String(describing: currentLabelTitle())).")
        XCTAssertFalse(element("chat-jump-to-latest").exists)

        // Agent replies end where the user's messages end, which is the room the labels use.
        let question = scrollView.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "user-message-", "anchor-page:Harbor:19")).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(wideReply), "The newest page's last reply should be reachable.")
        let replyRight = wideReply.frame.maxX
        XCTAssertGreaterThan(wideReply.frame.minX, anchors.frame.maxX, "Messages start right of the labels.")
        attachScreenshot(named: "chat-page-anchors-beside-latest-messages")
        XCTAssertTrue(scrollTranscriptUntilExists(question), "The newest page's question should be reachable.")
        XCTAssertLessThan(abs(question.frame.maxX - replyRight), 60,
                          "A wrapped agent reply should reach the user's messages' right edge; question=\(question.frame), reply right=\(replyRight).")

        // An old page is read on its own: the labels first read the older pages' titles.
        jump(to: "Topic 03")
        XCTAssertEqual(anchors.value as? String, "45 pages", "Scrolling the labels up reads the older pages' labels.")
        XCTAssertTrue(transcriptValue().hasPrefix("Showing earlier ") && transcriptValue().hasSuffix(" of 126 messages"), transcriptValue())
        XCTAssertLessThanOrEqual(renderedCount(), 40, "A jump renders the page's own window, not the pages around it.")
        XCTAssertTrue(transcriptContains("Topic 03 reply 1."), "The page's messages are shown.")
        XCTAssertFalse(chatPageSeparatorIsVisible("Harbor"), "The newest page is not rendered below a page jumped to.")
        XCTAssertFalse(chatPageSeparatorIsVisible("Topic 02"), "The page before it is not rendered until the reader scrolls up to it.")
        XCTAssertTrue(element("chat-jump-to-latest").exists, "An earlier page offers a way back to the newest messages.")
        attachScreenshot(named: "chat-page-anchors-jumped-to-old-page")

        // Scrolling on from there loads what follows, and the labels follow the transcript.
        let renderedAfterJump = renderedCount()
        for _ in 0..<80 where renderedCount() <= 44 {
            let before = renderedCount()
            scrollView.scroll(byDeltaX: 0, deltaY: -400)
            _ = waitUntil({ renderedCount() != before }, timeout: 0.5)
        }
        XCTAssertGreaterThan(renderedCount(), 44, "Scrolling down past the page's window should load the messages after it; rendered \(renderedAfterJump) then \(renderedCount()).")
        XCTAssertTrue(transcriptValue().hasPrefix("Showing earlier "), transcriptValue())
        XCTAssertTrue(waitUntil({ (currentLabelTitle() ?? "Topic 03") > "Topic 03" }, timeout: 10),
                      "The marked label follows the page at the top of the transcript; current=\(String(describing: currentLabelTitle())).")
        attachScreenshot(named: "chat-page-anchors-scrolled-on-from-old-page")

        func labelIsInView(_ title: String) -> Bool { label(title).exists && anchors.frame.contains(label(title).frame) }
        XCTAssertFalse(labelIsInView("Harbor"), "With an old page in view, the newest page's label is scrolled out of the labels.")
        element("chat-jump-to-latest").click()
        XCTAssertTrue(waitUntil({ transcriptValue().hasPrefix("Showing latest ") && !self.element("chat-jump-to-latest").exists }, timeout: 10),
                      "Latest returns to the newest messages; transcript=\(transcriptValue()).")
        XCTAssertTrue(waitUntil({ currentLabelTitle() == "Harbor" && labelIsInView("Harbor") }, timeout: 10),
                      "The labels scroll by themselves to the page now in view; current=\(String(describing: currentLabelTitle())).")
        XCTAssertTrue(waitUntil({ wideReply.exists && scrollView.frame.intersects(wideReply.frame) }, timeout: 10), "The newest reply is in view again.")

        // Below the labels, Jump to bottom takes an earlier page straight to the chat's end.
        let jumpToBottom = element("chat-page-anchors-jump-to-bottom")
        XCTAssertTrue(jumpToBottom.exists, "The labels end with a Jump to bottom arrow.")
        XCTAssertEqual(jumpToBottom.label, "Jump to bottom of chat")
        XCTAssertGreaterThanOrEqual(jumpToBottom.frame.minY, anchors.frame.maxY, "The button sits below the labels.")
        XCTAssertLessThan(jumpToBottom.frame.minY - anchors.frame.maxY, 16, "The button sits right under the last label.")
        XCTAssertEqual(jumpToBottom.frame.midX, anchors.frame.midX, accuracy: 2, "The arrow is centered across the labels.")
        XCTAssertLessThanOrEqual(jumpToBottom.frame.width, 30, "The button is an arrow alone, without text.")
        XCTAssertLessThan(jumpToBottom.frame.maxY, scrollView.frame.maxY, "The button stays over the transcript.")
        XCTAssertEqual(anchors.frame.midY, scrollView.frame.midY, accuracy: 4, "The button leaves the labels halfway down the transcript.")
        jump(to: "Topic 40")
        XCTAssertTrue(transcriptValue().hasPrefix("Showing earlier "), transcriptValue())
        XCTAssertFalse(wideReply.exists && scrollView.frame.intersects(wideReply.frame), "An earlier page is in view, away from the bottom.")
        attachScreenshot(named: "chat-page-anchors-jump-to-bottom-button")
        attachElementScreenshot(anchors, named: "chat-page-anchors-labels-closeup")
        attachElementScreenshot(jumpToBottom, named: "chat-page-anchors-jump-to-bottom-button-closeup")
        jumpToBottom.click()
        XCTAssertTrue(waitUntil({ transcriptValue().hasPrefix("Showing latest ") && !self.element("chat-jump-to-latest").exists
                && wideReply.exists && scrollView.frame.intersects(wideReply.frame) }, timeout: 3),
                      "Jump to bottom shows the chat's last reply at once; transcript=\(transcriptValue()).")
        XCTAssertTrue(waitUntil({ currentLabelTitle() == "Harbor" }, timeout: 10), "The newest page's label is marked again; current=\(String(describing: currentLabelTitle())).")
        attachScreenshot(named: "chat-page-anchors-after-jump-to-bottom")
        // It also returns from the newest messages scrolled up, where Latest is not offered.
        scrollView.scroll(byDeltaX: 0, deltaY: 3_000)
        for _ in 0..<5 where wideReply.exists && scrollView.frame.intersects(wideReply.frame) {
            scrollView.scroll(byDeltaX: 0, deltaY: 1_500)
        }
        XCTAssertFalse(wideReply.exists && scrollView.frame.intersects(wideReply.frame), "Scrolling up should take the last reply out of view.")
        XCTAssertTrue(transcriptValue().hasPrefix("Showing latest "), transcriptValue())
        XCTAssertFalse(element("chat-jump-to-latest").exists, "Latest is only offered on an earlier page.")
        jumpToBottom.click()
        XCTAssertTrue(waitUntil({ wideReply.exists && scrollView.frame.intersects(wideReply.frame) }, timeout: 3),
                      "Jump to bottom returns from the scrolled-up newest messages to the last reply at once; transcript=\(transcriptValue()).")

        // A page whose messages are already loaded is shown without reading it again, and its
        // title offers Recall; the page the next message continues does not.
        jump(to: "Glaciers")
        XCTAssertTrue(transcriptValue().hasPrefix("Showing earlier "), transcriptValue())
        let recallGlaciers = element("chat-page-recall-\(try XCTUnwrap(pageIDs["Glaciers"]))")
        XCTAssertTrue(recallGlaciers.waitToExist(timeout: 5), "An earlier page's title carries a Recall button.")
        XCTAssertEqual(recallGlaciers.label, "Recall this conversation")
        // The hint is a native tooltip, which XCUITest cannot read; the screenshot shows it.
        recallGlaciers.hover()
        _ = waitUntil({ false }, timeout: 2)
        attachScreenshot(named: "chat-page-recall-button-hint")
        recallGlaciers.click()
        let glaciersChip = element("composer-recalled-page-\(try XCTUnwrap(pageIDs["Glaciers"]))")
        XCTAssertTrue(waitUntil({ glaciersChip.exists && transcriptValue().hasPrefix("Showing latest ") && !self.element("chat-jump-to-latest").exists }, timeout: 10),
                      "Recall returns to the bottom of the chat and notes the page in the composer; transcript=\(transcriptValue()).")
        XCTAssertEqual(glaciersChip.label, "Recalling Glaciers")
        XCTAssertTrue(waitUntil({ wideReply.exists && scrollView.frame.intersects(wideReply.frame) }, timeout: 10), "The chat is at its newest reply.")
        XCTAssertFalse(element("chat-page-recall-\(try XCTUnwrap(pageIDs["Harbor"]))").exists, "The page being continued has nothing to recall.")
        attachScreenshot(named: "chat-page-recalling-in-composer")
        element("composer-recalled-page-remove-\(try XCTUnwrap(pageIDs["Glaciers"]))").click()
        XCTAssertTrue(waitUntil({ !glaciersChip.exists }, timeout: 5), "The recalled page can be dropped before sending.")

        // Recalling an old page sends it, and only it, with the next message.
        jump(to: "Topic 03")
        let recallTopic = element("chat-page-recall-\(try XCTUnwrap(pageIDs["Topic 03"]))")
        XCTAssertTrue(recallTopic.waitToExist(timeout: 5))
        recallTopic.click()
        let topicChip = element("composer-recalled-page-\(try XCTUnwrap(pageIDs["Topic 03"]))")
        XCTAssertTrue(waitUntil({ topicChip.exists && transcriptValue().hasPrefix("Showing latest ") }, timeout: 10), transcriptValue())
        XCTAssertEqual(topicChip.label, "Recalling Topic 03")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("What did we say before?")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: "What did we say before?") > 0 && self.noTurnIsRunning()
        }, timeout: 60), "The recalling turn should finish.")
        XCTAssertTrue(waitUntil({ !topicChip.exists }, timeout: 5), "The composer's note clears once the message is sent.")
        let historyData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let turns = try XCTUnwrap((try JSONSerialization.jsonObject(with: historyData) as? [String: Any])?["turns"] as? [[String: Any]])
        // The page classifier's own turns quote the message too; the chat's turn is not one of them.
        let recalled = try XCTUnwrap(turns.compactMap { $0["userText"] as? String }
            .last { $0.hasSuffix("What did we say before?") && !$0.hasPrefix("Classify the latest user message") })
        XCTAssertTrue(recalled.contains("anchor-page:Topic-03:1"), "The recalled page travels with the turn.")
        XCTAssertTrue(recalled.contains("Topic 03 reply 1."))
        XCTAssertFalse(recalled.contains("Topic 04 reply 1."), "Only the recalled page is carried.")
        XCTAssertFalse(recalled.contains("Glaciers reply 1."), "A page dropped from the composer is not carried.")

        // The lock persists across a relaunch; unlocked from the handle, the labels fold into it
        // once the pointer leaves them, and stay folded after a relaunch.
        refreshStandaloneChatSidebar()
        XCTAssertTrue(waitUntil({ anchors.exists && handle.value as? String == "locked" }, timeout: 10), "Locked labels stay open after a relaunch.")
        XCTAssertEqual(lock.value as? String, "locked", "The lock stays closed after a relaunch.")
        XCTAssertTrue(waitUntil({ label("Harbor").exists }, timeout: 5))
        handle.click()
        XCTAssertTrue(waitUntil({ handle.value as? String == "open" }, timeout: 5), "Clicking the locked handle unlocks the labels.")
        XCTAssertEqual(handle.label, "Lock chat pages open")
        XCTAssertTrue(waitUntil({ lock.value as? String == "unlocked" }, timeout: 2), "Unlocking opens the lock above the handle.")
        XCTAssertTrue(anchors.exists, "Unlocking under the pointer leaves the labels open until it leaves them.")
        moveOffLabels()
        XCTAssertTrue(waitUntil({ !anchors.exists && handle.value as? String == "folded" }, timeout: 5), "Unlocked labels fold back into the handle when the pointer leaves.")
        XCTAssertTrue(waitUntil({ !lock.exists }, timeout: 2), "The lock goes with the folded labels.")
        attachScreenshot(named: "chat-page-anchors-unlocked-folded")
        refreshStandaloneChatSidebar()
        XCTAssertTrue(waitUntil({ handle.exists && handle.value as? String == "folded" }, timeout: 10), "Unlocked labels stay folded into the handle after a relaunch.")
        XCTAssertFalse(anchors.exists)
    }

    // case-contract: test_standalone_chat_page_labels_search | Above the standalone chat's page labels, a small search field narrows them to the pages whose titles contain its text, read from the whole chat rather than only the newest forty labels, matching case-insensitively and literally: `chat page list --title <text>` returns those pages newest first, its --limit counting matches, surrounding spaces ignored, message text not searched, % and _ matching only themselves, no match an empty list, blank text the same as no filter, and --title without a value invalid_argument. In the chat, the field sits just above the labels the handle slides out, inside their hovered area; typing filters the labels, including a page older than the labels first read, and clicking a match jumps to that page; while the field has the keyboard, unlocked labels stay out after the pointer leaves them. Text that matches nothing shows No matching pages, and the clear button, or Escape, restores every label. The search is Playhouse-owned and shared by Claude and Codex, so one representative provider (Claude) covers the case.
    func test_standalone_chat_page_labels_search() throws {
        executionTimeAllowance = 240
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-page-search")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)

        // The oldest page lies beyond the newest forty the labels read at first.
        let topics = ["Kyoto temples"] + (1...42).map { String(format: "Topic %02d", $0) } + ["Kyoto ramen", "Harbor"]
        for title in topics {
            _ = try runCLI(["conversation", "send", chatID, "--message", "anchor-page:\(title.replacingOccurrences(of: " ", with: "-")):1"])
        }
        let listed = try XCTUnwrap((try runCLI(["chat", "page", "list", "--limit", "100"])["result"] as? [String: Any])?["pages"] as? [[String: Any]])
        var pageIDs: [String: String] = [:]
        for page in listed where (page["messageCount"] as? Int ?? 0) > 0 {
            pageIDs[try XCTUnwrap(page["title"] as? String)] = try XCTUnwrap(page["id"] as? String)
        }
        XCTAssertEqual(pageIDs.count, topics.count, "Each turn opens its own titled page.")

        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        waitForConversationLoad()

        let scrollView = element("conversation-scroll-view")
        let anchors = app.scrollViews.matching(identifier: "chat-page-anchors").firstMatch
        let handle = element("chat-page-anchors-handle")
        let search = element("chat-page-anchors-search")
        let clear = element("chat-page-anchors-search-clear")
        let noMatches = element("chat-page-anchors-no-matches")
        func label(_ title: String) -> XCUIElement { element("chat-page-anchor-\(pageIDs[title] ?? "missing")") }
        func shownTitles() -> [String] {
            anchors.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-page-anchor-")).allElementsBoundByIndex.map(\.label)
        }
        func moveOffLabels() {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).hover()
        }

        // The search sits just above the labels the handle slides out.
        XCTAssertTrue(handle.waitToExist(timeout: 10))
        XCTAssertFalse(search.exists, "The search folds away with the labels.")
        handle.hover()
        XCTAssertTrue(waitUntil({ anchors.exists && search.exists }, timeout: 5), "Hovering the handle shows the labels and their search.")
        XCTAssertLessThanOrEqual(search.frame.maxY, anchors.frame.minY + 1, "The search sits above the labels.")
        XCTAssertGreaterThan(search.frame.maxY, anchors.frame.minY - 12, "The search sits just above the labels.")
        // The field's text starts after the magnifying glass at the labels' leading edge.
        XCTAssertGreaterThanOrEqual(search.frame.minX, anchors.frame.minX - 1, "The search starts within the labels' column.")
        XCTAssertLessThanOrEqual(search.frame.minX, anchors.frame.minX + 20, "The search starts at the labels' leading edge.")
        XCTAssertLessThanOrEqual(search.frame.maxX, anchors.frame.maxX + 1, "The search is no wider than the labels.")
        XCTAssertFalse(label("Kyoto temples").exists, "The oldest page is not among the labels read first.")
        XCTAssertTrue(label("Harbor").exists)
        // The search is inside the labels' hovered area: resting on it keeps unlocked labels out.
        search.hover()
        _ = waitUntil({ false }, timeout: 0.8)
        XCTAssertTrue(anchors.exists && handle.value as? String == "open", "Hovering the search keeps the labels out.")
        attachScreenshot(named: "chat-page-labels-search-empty")
        attachRegionScreenshot([search, anchors], named: "chat-page-labels-search-empty-closeup")

        // Typing narrows the labels to matching titles from the whole chat.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        search.typeText("kyoto")
        XCTAssertTrue(waitUntil({ shownTitles() == ["Kyoto temples", "Kyoto ramen"] }, timeout: 5),
                      "The search shows only matching pages, oldest at the top; shown \(shownTitles()).")
        XCTAssertTrue(clear.exists, "Typed text offers a clear button.")
        attachScreenshot(named: "chat-page-labels-search-matches")
        attachRegionScreenshot([search, anchors], named: "chat-page-labels-search-matches-closeup")

        // While the search has the keyboard, unlocked labels stay out after the pointer leaves.
        moveOffLabels()
        _ = waitUntil({ false }, timeout: 0.8)
        XCTAssertTrue(anchors.exists && handle.value as? String == "open", "Labels stay out while their search has the keyboard.")

        // A match jumps to its page, even one older than the labels first read.
        label("Kyoto temples").click()
        XCTAssertTrue(waitUntil({
            (self.chatPageSeparators("Kyoto temples").first.map { $0.minY - scrollView.frame.minY } ?? 1_000) < 80
        }, timeout: 15), "Clicking a match shows its page from its first message.")
        XCTAssertTrue((scrollView.value as? String ?? "").hasPrefix("Showing earlier"), scrollView.value as? String ?? "")

        // Text that matches nothing says so; clearing shows every label again.
        handle.hover()
        XCTAssertTrue(waitUntil({ search.exists }, timeout: 5))
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        search.typeText(" zzz")
        XCTAssertTrue(waitUntil({ noMatches.exists && shownTitles().isEmpty }, timeout: 5), "Text matching no title shows No matching pages; shown \(shownTitles()).")
        attachScreenshot(named: "chat-page-labels-search-no-matches")
        attachRegionScreenshot([search, anchors], named: "chat-page-labels-search-no-matches-closeup")
        clear.click()
        XCTAssertTrue(waitUntil({ !noMatches.exists && label("Harbor").exists && !clear.exists }, timeout: 5), "Clearing restores every label.")
        XCTAssertEqual(search.value as? String ?? "", "", "Clearing empties the search.")

        // Escape clears too.
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        search.typeText("ramen")
        XCTAssertTrue(waitUntil({ shownTitles() == ["Kyoto ramen"] }, timeout: 5), "shown \(shownTitles())")
        search.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ label("Harbor").exists && label("Topic 42").exists }, timeout: 5), "Escape restores every label.")
        XCTAssertEqual(search.value as? String ?? "", "", "Escape empties the search.")
        XCTAssertFalse(clear.exists, "An empty search offers no clear button.")
    }
}

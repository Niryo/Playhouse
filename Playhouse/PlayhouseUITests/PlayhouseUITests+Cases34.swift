import AppKit
import Foundation
import Vision
import XCTest

extension PlayhouseUITests {
    // case-contract: test_claude_optimized_follow_up_starts_fresh_seeded_session | With optimized context on, a Claude task's follow-up starts a brand-new Claude session (launched with --session-id, never --resume) that becomes the task's session, while the first message, sent in Plan mode, started the conversation's original session. The fresh session's prompt begins with a Playhouse optimized context block, not part of the user's message, that maps the whole conversation by position (each turn's user message, agent message and tool-call counts, plan or final answer position), lists every message the user wrote in order with its position, carries the latest plan in full, states the conversation's total messages, tool calls and turns, and ends with the user's new message; a later follow-up rotates again, lists both earlier user messages and the latest final answer, and never repeats the agent's commentary. Its system prompt says the task uses optimized context, that the block is a summary, and points the agent at conversation read and conversation outline. Playhouse's own outcome nudges keep the session they nudge. With the mode back on full, the next follow-up resumes the latest session without a context block. Every turn stays in the visible transcript, and the plan turn is still recorded as a plan in conversation outline.
    func test_claude_optimized_follow_up_starts_fresh_seeded_session() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-optimized-follow-up")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOptimizedTask(title: "Optimized Claude follow-up", provider: "claude")
        openTask(named: "Optimized Claude follow-up")

        let optimizedButton = element("conversation-optimized-context-button")
        XCTAssertTrue(optimizedButton.waitToExist(timeout: 10), "A task's composer shows the Optimized context button.")
        let planButton = element("conversation-plan-button")
        XCTAssertLessThanOrEqual(planButton.frame.maxX, optimizedButton.frame.minX + 1, "The Optimized context button sits right after the Plan button.")
        XCTAssertLessThan(optimizedButton.frame.minX - planButton.frame.maxX, 30, "The Optimized context button sits next to the Plan button.")
        XCTAssertFalse(isModeOn("conversation-optimized-context-button"), "A task starts on full context.")
        XCTAssertLessThan(modeHighlightPixels("conversation-optimized-context-button"), 5, "The button has no orange highlight while off.")

        let firstMessage = "Inspect the readme and plan the change."
        setPlanMode(true)
        sendOptimizedComposerMessage(firstMessage)
        try waitForOptimizedTurn(executable: executable, ending: firstMessage, taskID: taskID)
        XCTAssertTrue(transcriptMessage(firstMessage).waitToExist(timeout: 10))
        let first = try optimizedClaudeTurn(executable: executable, ending: firstMessage)
        let originalSession = try XCTUnwrap(try taskRecord(id: taskID)?["claudeSessionID"] as? String)
        XCTAssertEqual(first["sessionID"] as? String, originalSession)
        XCTAssertFalse(optimizedInstructions(first).contains("This task uses optimized context"))
        setPlanMode(false)

        optimizedButton.click()
        XCTAssertTrue(waitUntil({ self.isModeOn("conversation-optimized-context-button") }, timeout: 5), "Clicking the button turns optimized context on.")
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "optimized" }, timeout: 10), "The task saves optimized context.")
        XCTAssertFalse(isModeOn("conversation-plan-button"), "Optimized context does not turn Plan mode on.")
        XCTAssertGreaterThan(modeHighlightPixels("conversation-optimized-context-button"), 20, "The button is highlighted orange while on.")
        attachRegionScreenshot([element("composer-attach-button"), optimizedButton], named: "Composer close-up: Optimized context on, next to Plan")
        attachElementScreenshot(optimizedButton, named: "The Optimized context button while on")

        let secondMessage = "Second request: keep the summary short."
        sendOptimizedComposerMessage(secondMessage)
        try waitForOptimizedTurn(executable: executable, ending: secondMessage, taskID: taskID)
        let second = try optimizedClaudeTurn(executable: executable, ending: secondMessage)
        let secondSession = try XCTUnwrap(try taskRecord(id: taskID)?["claudeSessionID"] as? String)
        XCTAssertNotEqual(secondSession, originalSession, "An optimized follow-up starts a session of its own.")
        XCTAssertEqual(second["sessionID"] as? String, secondSession)
        XCTAssertEqual(second["resumed"] as? Bool, false, "An optimized follow-up launches with --session-id, never --resume.")
        let prompt = try XCTUnwrap(second["userText"] as? String)
        XCTAssertTrue(prompt.hasPrefix("<playhouse-handoff-context>"))
        XCTAssertTrue(prompt.contains("Playhouse optimized context, not part of the user's message."))
        XCTAssertTrue(prompt.contains("Read anything else of task \(taskID.uppercased()) with conversation read"))
        XCTAssertTrue(prompt.contains("run help conversation --for task for its options"),
                      "The seed points at help for the command's options instead of copying them.")
        XCTAssertTrue(prompt.contains("@1: \(firstMessage)"), "The seed lists the user's messages with their positions.")
        XCTAssertTrue(prompt.contains("- Turn 1 (Plan mode): user @1; 1 agent message, 1 tool call; plan @3; ends @3"), prompt)
        XCTAssertTrue(prompt.contains("The latest plan (@3):\n\nInspection done: the workspace is ready."))
        XCTAssertFalse(prompt.contains("I'll inspect the workspace first."), "The agent's commentary is read on demand, not seeded.")
        XCTAssertTrue(prompt.hasSuffix("</playhouse-handoff-context>\n\n\(secondMessage)"))
        let instructions = optimizedInstructions(second)
        XCTAssertTrue(instructions.contains("This task uses optimized context."))
        XCTAssertTrue(instructions.contains("It is a summary, not the whole conversation"))
        XCTAssertTrue(instructions.contains(" conversation read "))
        XCTAssertTrue(instructions.contains(" conversation outline "))
        let nudges = try optimizedClaudeTurns(executable: executable).filter {
            (($0["userText"] as? String) ?? "").lowercased().contains("playhouse internal outcome nudge:")
        }
        XCTAssertFalse(nudges.isEmpty, "Turns that report no outcome get Playhouse's nudge.")
        for nudge in nudges {
            XCTAssertEqual(nudge["resumed"] as? Bool, true, "A Playhouse nudge resumes the session it nudges.")
            XCTAssertTrue([originalSession, secondSession].contains(nudge["sessionID"] as? String ?? ""))
        }

        let thirdMessage = "Third request: list the next steps."
        let beforeThird = try XCTUnwrap(try runCLI(["conversation", "outline", taskID])["result"] as? [String: Any])
        sendOptimizedComposerMessage(thirdMessage)
        try waitForOptimizedTurn(executable: executable, ending: thirdMessage, taskID: taskID)
        let third = try optimizedClaudeTurn(executable: executable, ending: thirdMessage)
        let thirdSession = try XCTUnwrap(try taskRecord(id: taskID)?["claudeSessionID"] as? String)
        XCTAssertFalse([originalSession, secondSession].contains(thirdSession), "Every optimized follow-up rotates the session.")
        let outline = try XCTUnwrap(try runCLI(["conversation", "outline", taskID])["result"] as? [String: Any])
        let outlineTurns = try XCTUnwrap(outline["turns"] as? [[String: Any]])
        let secondPosition = try XCTUnwrap(outlineTurns.first {
            $0["startedBy"] as? String == "user" && ($0["turn"] as? Int ?? 0) > 1
        }?["userPositions"] as? [String]).first
        let thirdPrompt = try XCTUnwrap(third["userText"] as? String)
        XCTAssertTrue(thirdPrompt.contains("@1: \(firstMessage)"))
        XCTAssertTrue(thirdPrompt.contains("@\(secondPosition ?? ""): \(secondMessage)"))
        XCTAssertTrue(thirdPrompt.contains("The latest plan (@3):"))
        XCTAssertTrue(thirdPrompt.contains("The latest final answer (@"))
        func counted(_ value: Any?, _ noun: String) -> String {
            let number = value as? Int ?? -1
            return "\(number) \(noun)\(number == 1 ? "" : "s")"
        }
        XCTAssertTrue(thirdPrompt.contains(
            "Conversation outline: \(counted(beforeThird["totalMessages"], "message")) and \(counted(beforeThird["totalToolCalls"], "tool call")) in \(counted(beforeThird["totalTurns"], "turn"))."
        ), "The seed states the conversation's total messages, tool calls and turns.")
        XCTAssertEqual(outlineTurns.first?["plan"] as? Bool, true, "The Plan mode turn stays recorded as a plan.")
        XCTAssertEqual(outlineTurns.filter { $0["freshSession"] as? Bool == true }.count, 2)

        optimizedButton.click()
        XCTAssertTrue(waitUntil({ !self.isModeOn("conversation-optimized-context-button") }, timeout: 5), "Clicking again turns optimized context off.")
        XCTAssertTrue(waitUntil({ self.modeHighlightPixels("conversation-optimized-context-button") < 5 }, timeout: 3), "The button loses its highlight when turned off.")
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "full" }, timeout: 10))
        let fourthMessage = "Fourth request: wrap up."
        sendOptimizedComposerMessage(fourthMessage)
        try waitForOptimizedTurn(executable: executable, ending: fourthMessage, taskID: taskID)
        let fourth = try optimizedClaudeTurn(executable: executable, ending: fourthMessage)
        XCTAssertEqual(fourth["resumed"] as? Bool, true, "Back on full context, a follow-up resumes the latest session.")
        XCTAssertEqual(fourth["sessionID"] as? String, thirdSession)
        XCTAssertFalse((fourth["userText"] as? String ?? "").contains("<playhouse-handoff-context>"))

        for message in [firstMessage, secondMessage, thirdMessage, fourthMessage] {
            XCTAssertTrue(revealOptimizedTranscriptMessage(message), "Rotating sessions never hides a turn from the transcript: \(message)")
        }
        XCTAssertEqual(app.groups.matching(NSPredicate(format: "label CONTAINS %@", "<playhouse-handoff-context>")).count, 0,
                       "The transcript shows what the user typed, not the seed.")
        attachScreenshot(named: "Claude optimized context: every follow-up stays in the transcript")
    }

    // case-contract: test_codex_optimized_follow_up_starts_fresh_seeded_session | With optimized context on, a Codex task's follow-up starts a new Codex thread with thread/start instead of resuming the old one with thread/resume, runs its turn/start on that new thread, and the task's Codex thread ID follows it. The new thread's developer instructions carry the optimized-context guidance, and the turn's input begins with the Playhouse optimized context block listing the earlier user messages and the plan from the Plan mode turn by position, followed by the user's new message; the Plan mode turn's commentary, command and plan are numbered as for Claude, so conversation read at 2.1 returns the command. While a Codex goal is set, a follow-up keeps the goal's thread with no context block and no thread/start, and once the goal is cleared the next follow-up rotates again. A follow-up sent with the mode back on full resumes the latest thread with thread/resume and no context block. With the mode on again, switching the task to Claude gives Claude's first session the optimized seed, listing the messages Codex answered, instead of the full provider-switch handoff.
    func test_codex_optimized_follow_up_starts_fresh_seeded_session() throws {
        executionTimeAllowance = 360 // Seven turns across a goal, both context modes and a switch to Claude, each with its outcome nudge.
        let executable = dataDirectory.appendingPathComponent("codex-fixture-optimized-goal-fresh-threads-unique-turns-success")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-success"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = executable.path
        let claudeExecutable = try XCTUnwrap(try installClaudeFixture(named: "claude-fixture-ui-optimized-after-switch")["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path)
        let taskID = try createOptimizedTask(title: "Optimized Codex follow-up", provider: "codex")
        openTask(named: "Optimized Codex follow-up")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        // Read without XCTUnwrap: polling runs before the fixture has written its history.
        func history() throws -> [String: Any] {
            guard FileManager.default.fileExists(atPath: historyURL.path) else { return [:] }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any] ?? [:]
        }
        func turn(ending message: String) throws -> [String: Any] {
            try XCTUnwrap((try history()["turns"] as? [[String: Any]])?.last { ($0["userMessage"] as? String ?? "").hasSuffix(message) },
                          "The Codex fixture never received a turn ending with \(message).")
        }
        func waitForTurn(_ message: String) {
            XCTAssertTrue(waitUntil({
                ((try? history()["turns"] as? [[String: Any]]) ?? []).contains { ($0["userMessage"] as? String ?? "").hasSuffix(message) }
                    && (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true
            }, timeout: 30), "The Codex turn for \(message) should finish.")
        }

        let optimizedButton = element("conversation-optimized-context-button")
        let planButton = element("conversation-plan-button")
        let goalButton = element("conversation-goal-button")
        XCTAssertTrue(optimizedButton.waitToExist(timeout: 10) && goalButton.waitToExist(timeout: 10))
        XCTAssertLessThanOrEqual(planButton.frame.maxX, optimizedButton.frame.minX + 1, "Optimized context sits right after Plan.")
        XCTAssertLessThanOrEqual(optimizedButton.frame.maxX, goalButton.frame.minX + 1, "Goal follows Optimized context.")

        let firstMessage = "Draft the rollout plan. Run one command first."
        setPlanMode(true)
        sendOptimizedComposerMessage(firstMessage)
        waitForTurn(firstMessage)
        let originalThread = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        XCTAssertEqual(try turn(ending: firstMessage)["turnThreadID"] as? String, originalThread)
        let startsBefore = (try history()["threadStarts"] as? [[String: Any]])?.count ?? 0
        setPlanMode(false)

        optimizedButton.click()
        XCTAssertTrue(waitUntil({ self.isModeOn("conversation-optimized-context-button") }, timeout: 5))
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "optimized" }, timeout: 10))
        XCTAssertTrue(isModeOn("conversation-optimized-context-button") && !isModeOn("conversation-goal-button"),
                      "Optimized context is independent of Goal.")
        attachRegionScreenshot([planButton, goalButton], named: "Codex composer: Plan, Optimized context (on) and Goal")

        let secondMessage = "Now estimate the rollout effort."
        sendOptimizedComposerMessage(secondMessage)
        waitForTurn(secondMessage)
        let newThread = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        XCTAssertNotEqual(newThread, originalThread, "An optimized follow-up starts a new Codex thread.")
        let starts = try XCTUnwrap(try history()["threadStarts"] as? [[String: Any]])
        XCTAssertEqual(starts.count, startsBefore + 1, "The follow-up sent thread/start once.")
        XCTAssertEqual(starts.last?["threadID"] as? String, newThread)
        XCTAssertTrue((starts.last?["developerInstructions"] as? String ?? "").contains("This task uses optimized context."))
        // The window then loads the new thread itself to follow it (a thread/resume of its own), so
        // the fresh start is proven by thread/start and the turn's thread, not by resume counts.
        let second = try turn(ending: secondMessage)
        XCTAssertEqual(second["turnThreadID"] as? String, newThread, "turn/start runs on the new thread.")
        let prompt = try XCTUnwrap(second["userMessage"] as? String)
        XCTAssertTrue(prompt.hasPrefix("<playhouse-handoff-context>"))
        XCTAssertTrue(prompt.contains("@1: \(firstMessage)"))
        XCTAssertTrue(prompt.contains("- Turn 1 (Plan mode): user @1; 1 agent message, 1 tool call; plan @3; ends @3"),
                      "Codex's commentary, command and plan are numbered the same way as Claude's: \(prompt)")
        let command = try XCTUnwrap((try runCLI(["conversation", "read", taskID, "--at", "2.1"])["result"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(command.first?["kind"] as? String, "tool", "The Codex command follows its commentary, message 2.")
        XCTAssertTrue("\(command.first?["title"] ?? "") \(command.first?["text"] ?? "")".contains("git status"))
        XCTAssertTrue(prompt.contains("The latest plan (@"))
        XCTAssertTrue(prompt.hasSuffix("</playhouse-handoff-context>\n\n\(secondMessage)"))
        XCTAssertTrue(transcriptMessage(secondMessage).waitToExist(timeout: 10), "The transcript shows the typed message.")

        // A Codex goal belongs to its thread, so while one is set a follow-up keeps that thread.
        _ = try runCLI(["conversation", "goal", taskID, "set", "--text", "Ship the rollout."])
        let goalMessage = "Keep going toward the goal."
        sendOptimizedComposerMessage(goalMessage)
        waitForTurn(goalMessage)
        XCTAssertEqual(try taskRecord(id: taskID)?["codexThreadID"] as? String, newThread, "A follow-up keeps the thread that holds the goal.")
        XCTAssertEqual(try turn(ending: goalMessage)["turnThreadID"] as? String, newThread)
        XCTAssertFalse((try turn(ending: goalMessage)["userMessage"] as? String ?? "").contains("<playhouse-handoff-context>"))
        XCTAssertEqual((try history()["threadStarts"] as? [[String: Any]])?.count, startsBefore + 1, "No thread starts while the goal is set.")
        _ = try runCLI(["conversation", "goal", taskID, "clear"])
        let clearedMessage = "The goal is done; summarize the rollout."
        sendOptimizedComposerMessage(clearedMessage)
        waitForTurn(clearedMessage)
        let clearedThread = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        XCTAssertNotEqual(clearedThread, newThread, "Once the goal is cleared, follow-ups rotate again.")
        XCTAssertTrue((try turn(ending: clearedMessage)["userMessage"] as? String ?? "").hasPrefix("<playhouse-handoff-context>"))

        optimizedButton.click()
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "full" }, timeout: 10))
        let thirdMessage = "Confirm the estimate."
        sendOptimizedComposerMessage(thirdMessage)
        waitForTurn(thirdMessage)
        XCTAssertEqual(try taskRecord(id: taskID)?["codexThreadID"] as? String, clearedThread, "Back on full context, the task keeps its latest thread.")
        XCTAssertEqual(try turn(ending: thirdMessage)["turnThreadID"] as? String, clearedThread)
        XCTAssertTrue((try history()["threadResumes"] as? [String] ?? []).contains(clearedThread), "A full-context follow-up resumes the latest thread.")
        XCTAssertFalse((try turn(ending: thirdMessage)["userMessage"] as? String ?? "").contains("<playhouse-handoff-context>"))

        // A provider's first session in an optimized task gets the optimized seed, not the full handoff.
        optimizedButton.click()
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "optimized" }, timeout: 10))
        element("conversation-provider-menu").click()
        let claudeChoice = app.menuItems["conversation-provider-claude"]
        XCTAssertTrue(claudeChoice.waitToExist(timeout: 5))
        claudeChoice.click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["conversationProvider"] as? String) == "claude" }, timeout: 10))
        let switchMessage = "Claude, take over from here."
        sendOptimizedComposerMessage(switchMessage)
        try waitForOptimizedTurn(executable: claudeExecutable, ending: switchMessage, taskID: taskID)
        let switched = try optimizedClaudeTurn(executable: claudeExecutable, ending: switchMessage)
        let switchedPrompt = switched["userText"] as? String ?? ""
        XCTAssertEqual(switched["resumed"] as? Bool, false)
        XCTAssertTrue(switchedPrompt.hasPrefix("<playhouse-handoff-context>\nPlayhouse optimized context"), "The new provider's first session gets the optimized seed.")
        XCTAssertTrue(switchedPrompt.contains("@1: \(firstMessage)"))
        XCTAssertTrue(switchedPrompt.contains(": \(thirdMessage)"), "The seed lists the messages Codex answered.")
        XCTAssertFalse(switchedPrompt.contains("continued with another assistant while you were not active"),
                       "The optimized seed replaces the full provider-switch handoff.")
        for message in [firstMessage, secondMessage, goalMessage, clearedMessage, thirdMessage, switchMessage] {
            XCTAssertTrue(revealOptimizedTranscriptMessage(message), "Every Codex turn stays in the transcript: \(message)")
        }
        attachScreenshot(named: "Codex optimized context: the follow-ups after a fresh thread")
    }

    // case-contract: test_conversation_read_positions_messages_and_tools | conversation outline and conversation read share one numbering of a task's whole conversation: messages take whole-number positions from 1 in order (the user's message, the agent's commentary, its final answer) and each tool call takes a decimal position under the message it followed, such as 2.1. The outline reports totals and, for each turn, its user message, agent message and tool-call counts, its final answer position and whether it ran in Plan mode. read --at returns exactly the listed entries with their kind and text, a range returns messages only unless --include-tools adds the tool calls with their title and status, and --kinds final lists every turn's final answer without the work before it. A position that is not a number, a position past the end, a range whose start follows its end, --at combined with a range, and an unknown kind are each rejected with a clear error.
    func test_conversation_read_positions_messages_and_tools() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-conversation-read")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOptimizedTask(title: "Conversation positions", provider: "claude")
        openTask(named: "Conversation positions")
        let firstMessage = "Inspect the readme for the positions check."
        let secondMessage = "Reply briefly for the positions check."
        setPlanMode(true)
        sendOptimizedComposerMessage(firstMessage)
        try waitForOptimizedTurn(executable: executable, ending: firstMessage, taskID: taskID)
        setPlanMode(false)
        sendOptimizedComposerMessage(secondMessage)
        try waitForOptimizedTurn(executable: executable, ending: secondMessage, taskID: taskID)

        let outline = try XCTUnwrap(try runCLI(["conversation", "outline", taskID])["result"] as? [String: Any])
        XCTAssertEqual(outline["totalTurns"] as? Int, 2, "\(outline)")
        let turns = try XCTUnwrap(outline["turns"] as? [[String: Any]])
        XCTAssertEqual(turns[0]["userPositions"] as? [String], ["1"])
        XCTAssertEqual(turns[0]["agentMessages"] as? Int, 1)
        XCTAssertEqual(turns[0]["toolCalls"] as? Int, 2)
        XCTAssertEqual(turns[0]["plan"] as? Bool, true)
        XCTAssertEqual(turns[0]["finalAnswerPositions"] as? [String], ["3"])
        XCTAssertEqual(outline["latestPlanPosition"] as? String, "3")
        XCTAssertEqual(turns[1]["userPositions"] as? [String], ["4"])
        XCTAssertEqual(turns[1]["plan"] as? Bool, false)
        XCTAssertEqual(outline["totalToolCalls"] as? Int, (turns[0]["toolCalls"] as? Int ?? 0) + (turns[1]["toolCalls"] as? Int ?? 0))
        XCTAssertEqual(outline["totalMessages"] as? Int, Int(turns[1]["lastPosition"] as? String ?? ""))

        func read(_ arguments: [String]) throws -> [[String: Any]] {
            try XCTUnwrap((try runCLI(["conversation", "read", taskID] + arguments)["result"] as? [String: Any])?["entries"] as? [[String: Any]])
        }
        let picked = try read(["--at", "1,3"])
        XCTAssertEqual(picked.map { "\($0["position"] ?? "")/\($0["kind"] ?? "")" }, ["1/user", "3/plan"])
        // What read returns is what the transcript shows at those positions.
        for entry in picked {
            let text = try XCTUnwrap(entry["text"] as? String)
            let row = entry["kind"] as? String == "user"
                ? transcriptMessage(text)
                : app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", text)).firstMatch
            XCTAssertTrue(revealInConversation(row), "The transcript shows the entry read at position \(entry["position"] ?? ""): \(text)")
        }
        attachScreenshot(named: "The transcript entries conversation read returns at positions 1 and 3")
        let messages = try read(["--from", "1", "--to", "3"])
        XCTAssertEqual(messages.compactMap { $0["position"] as? String }, ["1", "2", "3"], "A range holds messages only by default.")
        XCTAssertEqual(messages[1]["kind"] as? String, "agent")
        XCTAssertEqual(messages[1]["text"] as? String, "I'll inspect the workspace first.")
        let withTools = try read(["--from", "1", "--to", "3", "--include-tools"])
        let tools = withTools.filter { $0["kind"] as? String == "tool" }
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools.compactMap { $0["position"] as? String }, ["2.1", "2.2"],
                       "The Read call follows the commentary, message 2, and the outcome report follows it.")
        XCTAssertTrue((tools.first?["title"] as? String ?? "").contains("README.md"))
        XCTAssertFalse((tools.first?["status"] as? String ?? "").isEmpty)
        let positions = withTools.compactMap { $0["position"] as? String }
        XCTAssertLessThan(try XCTUnwrap(positions.firstIndex(of: "2.1")), try XCTUnwrap(positions.firstIndex(of: "3")))
        XCTAssertTrue((try read(["--at", "2.1"]).first?["title"] as? String ?? "").contains("README.md"))
        let finals = try read(["--kinds", "final,plan"])
        XCTAssertEqual(finals.compactMap { $0["position"] as? String },
                       (turns[0]["finalAnswerPositions"] as? [String] ?? []) + (turns[1]["finalAnswerPositions"] as? [String] ?? []))
        XCTAssertEqual(Set(finals.compactMap { $0["kind"] as? String }), ["plan", "final"])

        for (arguments, code, fragment) in [
            (["--at", "two"], "invalid_argument", "is not a conversation position"),
            (["--at", "999"], "not_found", "Nothing is at position 999"),
            (["--from", "999"], "not_found", "past the end of the conversation"),
            (["--from", "3", "--to", "1"], "invalid_argument", "comes after"),
            (["--at", "1", "--from", "1"], "invalid_argument", "choose one"),
            (["--kinds", "thinking"], "invalid_argument", "Unknown entry kind"),
        ] {
            // The CLI exits 3 when the bridge reports something not found, 2 for invalid input.
            let failed = try runCLI(["conversation", "read", taskID] + arguments, expectedStatus: code == "not_found" ? 3 : 2)
            let error = try XCTUnwrap(failed["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, code, "\(arguments)")
            XCTAssertTrue((error["message"] as? String ?? "").contains(fragment), "\(arguments): \(error)")
        }
    }

    // case-contract: test_optimized_context_steer_and_queued_follow_ups | With optimized context on, a steer joins the running turn in that turn's own session instead of starting a new one, and follow-ups queued while the turn runs are each delivered afterwards in a fresh seeded session of their own, including the second one, which was queued against a session the first follow-up replaced, so no queued follow-up is stranded. The queued follow-ups are listed while they wait. The context mode is saved on the task, reported by task get and conversation context-mode, and survives a restart (of the daemon from the CLI, of the app in the window, where the button is still on); an unknown mode is rejected, and the standalone chat, which pages its own context, has no context mode to set and no Optimized context button in its composer.
    func test_optimized_context_steer_and_queued_follow_ups() throws {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-optimized-steer-queue")
        environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOptimizedTask(title: "Optimized steer and queue", provider: "claude")
        let rejected = try runCLI(["conversation", "context-mode", taskID, "set", "compact"], expectedStatus: 2)
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertTrue(((rejected["error"] as? [String: Any])?["message"] as? String ?? "").contains("full, optimized"))
        XCTAssertEqual(try taskRecord(id: taskID)?["conversationContextMode"] as? String, "full")
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        let chatRejected = try runCLI(["conversation", "context-mode", chatID, "set", "optimized"], expectedStatus: 2)
        XCTAssertEqual((chatRejected["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertTrue(((chatRejected["error"] as? [String: Any])?["message"] as? String ?? "").contains("already splits its context into pages"))

        openTask(named: "Optimized steer and queue")
        sendOptimizedComposerMessage("Start the conversation.")
        try waitForOptimizedTurn(executable: executable, ending: "Start the conversation.", taskID: taskID)
        let optimizedButton = element("conversation-optimized-context-button")
        optimizedButton.click()
        XCTAssertTrue(waitUntil({ self.optimizedContextMode(taskID) == "optimized" }, timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["conversationContextMode"] as? String, "optimized")

        let heldMessage = "Hold for a steer while optimized."
        try Data("Hold the steered answer.\n".utf8).write(to: URL(fileURLWithPath: executable + ".steer-answer-pause"))
        sendOptimizedComposerMessage(heldMessage)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".steer-ready") }, timeout: 30), "The held turn waits for a steer.")
        let heldSession = try XCTUnwrap(try taskRecord(id: taskID)?["claudeSessionID"] as? String)
        let composer = element("message-composer")
        let steerText = "Steer: keep it short."
        composer.click()
        composer.typeText(steerText)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(steerText).waitToExist(timeout: 10), "The steer joins the running turn's transcript.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".steer-answer-ready") }, timeout: 30), "The steer reached the held turn.")
        for text in ["First queued follow-up.", "Second queued follow-up."] {
            composer.click()
            composer.typeText(text)
            composer.typeKey(.return, modifierFlags: [])
        }
        XCTAssertTrue(waitUntil({ ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count ?? 0) == 2 }, timeout: 10),
                      "Return while the turn runs queues both follow-ups.")
        let queued = try XCTUnwrap(try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])
        for text in ["First queued follow-up.", "Second queued follow-up."] {
            let id = try XCTUnwrap(queued.first { $0["text"] as? String == text }?["id"] as? String)
            let row = element("queued-message-text-\(id)")
            XCTAssertTrue(row.waitToExist(timeout: 10), "The window lists the queued follow-up: \(text)")
            XCTAssertEqual(row.value as? String, text)
        }
        attachScreenshot(named: "Optimized context: a steer in the running turn and two queued follow-ups")
        try Data("Release.\n".utf8).write(to: URL(fileURLWithPath: executable + ".steer-answer-release"))
        XCTAssertTrue(waitUntil({ ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count ?? 1) == 0 }, timeout: 60),
                      "Every queued follow-up is delivered, none stranded on a replaced session.")
        try waitForOptimizedTurn(executable: executable, ending: "Second queued follow-up.", taskID: taskID)

        let held = try optimizedClaudeTurn(executable: executable, ending: heldMessage)
        XCTAssertEqual(held["sessionID"] as? String, heldSession)
        // A seed legitimately repeats the steer; what matters is that no turn was sent for it.
        XCTAssertTrue(try optimizedClaudeTurns(executable: executable).allSatisfy {
            ((($0["userText"] as? String) ?? "").components(separatedBy: "</playhouse-handoff-context>").last ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines) != steerText
        },
                      "The steer is never sent as a turn of its own.")
        let first = try optimizedClaudeTurn(executable: executable, ending: "First queued follow-up.")
        let second = try optimizedClaudeTurn(executable: executable, ending: "Second queued follow-up.")
        XCTAssertEqual(Set([heldSession, first["sessionID"] as? String ?? "", second["sessionID"] as? String ?? ""]).count, 3,
                       "Each queued follow-up starts its own fresh session.")
        for turn in [first, second] {
            XCTAssertEqual(turn["resumed"] as? Bool, false)
            XCTAssertTrue((turn["userText"] as? String ?? "").contains(heldMessage), "The seed lists the earlier user messages.")
        }
        XCTAssertTrue((second["userText"] as? String ?? "").contains("(steer): \(steerText)"), "The seed marks a steer the user sent.")
        XCTAssertTrue((second["userText"] as? String ?? "").contains("First queued follow-up."))
        XCTAssertEqual(try taskRecord(id: taskID)?["claudeSessionID"] as? String, second["sessionID"] as? String)
        for text in [heldMessage, steerText, "First queued follow-up.", "Second queued follow-up."] {
            XCTAssertTrue(revealOptimizedTranscriptMessage(text), "The transcript keeps \(text)")
        }
        attachScreenshot(named: "Optimized context: both queued follow-ups delivered after the steered turn")

        relaunchApp()
        openTask(named: "Optimized steer and queue")
        XCTAssertTrue(element("conversation-optimized-context-button").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.isModeOn("conversation-optimized-context-button") }, timeout: 10),
                      "The task's optimized context stays on after the app restarts.")
        attachElementScreenshot(element("conversation-optimized-context-button"), named: "Optimized context stays on after relaunch")

        // The standalone chat pages its own context, so its composer has no Optimized context button.
        // Its sidebar opens from the board.
        element("back-to-board-button").click()
        XCTAssertTrue(element("chat-sidebar-button").waitToExist(timeout: 15))
        element("chat-sidebar-button").click()
        let chatSidebar = element("chat-sidebar")
        XCTAssertTrue(chatSidebar.waitToExist(timeout: 10))
        XCTAssertTrue(chatSidebar.descendants(matching: .any).matching(identifier: "message-composer").firstMatch.waitToExist(timeout: 10),
                      "The chat sidebar shows its composer.")
        XCTAssertFalse(chatSidebar.descendants(matching: .any).matching(identifier: "conversation-optimized-context-button").firstMatch.exists,
                       "The standalone chat's composer has no Optimized context button.")
        attachScreenshot(named: "The standalone chat composer has no Optimized context button")
    }

    // MARK: - Optimized context helpers

    /// Scrolls the lazy transcript until the user message with this exact text is rendered and
    /// fully visible: earlier rows only exist once scrolled near.
    func revealOptimizedTranscriptMessage(_ text: String) -> Bool {
        let scrollView = element("conversation-scroll-view")
        let target = transcriptMessage(text)
        for direction in [CGFloat(600), CGFloat(-600)] {
            for _ in 0..<20 {
                if target.exists { return revealInConversation(target) }
                guard scrollView.exists else { return false }
                scrollView.scroll(byDeltaX: 0, deltaY: direction)
                _ = target.waitToExist(timeout: 0.5)
            }
        }
        return target.exists && revealInConversation(target)
    }

    func createOptimizedTask(title: String, provider: String) throws -> String {
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
        ])["result"] as? [String: Any])
        XCTAssertTrue(app.buttons[title].waitToExist(timeout: 10))
        return try XCTUnwrap(created["id"] as? String)
    }

    func sendOptimizedComposerMessage(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10), file: file, line: line)
        composer.click()
        composer.typeText(text)
        element("send-message-button").click()
    }

    func optimizedContextMode(_ taskID: String) -> String? {
        (try? runCLI(["conversation", "context-mode", taskID])["result"] as? [String: Any])?["mode"] as? String
    }

    func optimizedClaudeTurns(executable: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: executable + ".history")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (history?["turns"] as? [[String: Any]] ?? []).filter {
            !(($0["userText"] as? String) ?? "").hasPrefix("Write a concise task title")
        }
    }

    func optimizedClaudeTurn(executable: String, ending message: String) throws -> [String: Any] {
        try XCTUnwrap(try optimizedClaudeTurns(executable: executable).last { (($0["userText"] as? String) ?? "").hasSuffix(message) },
                      "The Claude fixture never received a turn ending with \(message).")
    }

    func optimizedInstructions(_ turn: [String: Any]) -> String {
        let arguments = turn["arguments"] as? [String] ?? []
        guard let index = arguments.firstIndex(of: "--append-system-prompt"), index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }

    /// Waits until the provider received the turn and the task settled after it (its nudge included).
    func waitForOptimizedTurn(executable: String, ending message: String, taskID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(waitUntil({
            ((try? self.optimizedClaudeTurns(executable: executable)) ?? []).contains { (($0["userText"] as? String) ?? "").hasSuffix(message) }
                && (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true
                && !self.element("pause-response-button").exists
        }, timeout: 45), "The turn for \(message) should finish.", file: file, line: line)
    }

    // case-contract: test_keyboard_shortcuts_press_buttons_and_name_them_in_hover_hints | Important buttons have keyboard shortcuts that press them, and every button with a shortcut names it at the end of its hover hint, which reads exactly that text, keys and modifiers included. On the board, Command-N opens a new task, which the CLI lists as Untitled task, Shift-Command-C opens and closes the standalone chat and Shift-Command-D opens and closes the Done archive, and their hover hints read Create a new task (⌘N), Open the standalone chat (⇧⌘C) and Browse completed tasks (⇧⌘D). In the new task, Shift-Command-P turns Plan mode on and off (hint Plan before making changes (⇧⌘P)), Shift-Command-R opens the Add repository picker (hint Add a repository (⇧⌘R)), the schedule hint's Done button names Return, its default-action key (Use this schedule; Send then schedules the task (Return)), Control-Command-S hides and shows the task sidebar (hint Hide sidebar (⌃⌘S)), Shift-Command-K opens the Skills page (hint Skills, Rules & MCP (⇧⌘K)), whose close button, a Button atom with the cancel shortcut, reads Close (Esc) and, opened from a focused composer, closes it on Escape, after which typing still goes to the composer, and Command-[ returns to the board (hint Back to Kanban (⌘[)). In a Codex task with a repository worktree, Control-` opens the terminal (hint Open a terminal in this task's worktree (⌃`)) and hides it again while the shell has focus, and Command-. stops a running turn (hint Pause Codex response (⌘.)), which then offers Continue and leaves the task Waiting Response. A Button atom's shortcut prop takes default, cancel, or cmd, ctrl or option with any other modifiers and a key, joined by +: the Plugin Catalog's Button page has a Shortcut button that Shift-Command-B presses (Pressed 1 times) and whose hover hint reads Shift-Command-B presses it (⇧⌘B); `plugin render` reports that button's shortcut prop and runs its onPress, renders default, cancel and key combinations (cmd+shift+b, ctrl+option+t, option+`, cmd+], cmd+;, ctrl+return, cmd++) without errors, and reports in errors with exit 1, naming the shortcut, an invalid shortcut (empty, a modifier with no key, an unknown or repeated modifier, a key that is neither one character nor a key name, or a key with no cmd, ctrl or option, such as n, shift+n or return, which would take it from typing) and one Playhouse uses itself, whatever the order of its modifiers (cmd+n, shift+cmd+d, ctrl+`, or the menu bar's cmd+q).
    func test_keyboard_shortcuts_press_buttons_and_name_them_in_hover_hints() throws {
        executionTimeAllowance = 300 // It hovers a dozen buttons long enough for their tooltips.
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold-interrupt").path
        codexFixtureExecutable = executable
        let ready = URL(fileURLWithPath: executable + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable + ".interrupt-received")
        let release = URL(fileURLWithPath: executable + ".interrupt-release")
        for marker in [ready, received, release] { try? FileManager.default.removeItem(at: marker) }
        // A titled task with a repository gets its worktree at once, so its terminal can open.
        let workTaskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Shortcut work", "--prompt", "Fixture task description.", "--provider", "codex",
        ])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["task", "repository", "add", workTaskID, "--repo", fixture.primary.path])

        launchApp(defaultParent: fixture.parent.path)
        let newTask = element("new-task-button")
        XCTAssertTrue(newTask.waitToExist(timeout: 15), "The board shows its New Task button.")
        assertShortcutHelpText(for: newTask, equals: "Create a new task (⌘N)")
        assertShortcutHelpText(for: element("chat-sidebar-button"), equals: "Open the standalone chat (⇧⌘C)")
        assertShortcutHelpText(for: element("done-archive-button"), equals: "Browse completed tasks (⇧⌘D)")

        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("done-archive-title").waitToExist(timeout: 5), "Shift-Command-D opens the Done archive.")
        attachScreenshot(named: "Shift-Command-D opened the Done archive")
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil({ !self.element("done-archive-title").exists }, timeout: 5), "Shift-Command-D closes it again.")

        app.typeKey("n", modifierFlags: .command)
        let back = element("back-to-board-button")
        XCTAssertTrue(back.waitToExist(timeout: 15), "Command-N opens a new task.")
        XCTAssertTrue(waitUntil({
            let tasks = ((try? self.runCLI(["task", "list"]))?["result"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
            return Set(tasks.compactMap { $0["title"] as? String }) == ["Shortcut work", "Untitled task"]
        }, timeout: 10), "The new task is saved, and the CLI lists it beside the fixture task.")

        let plan = element("conversation-plan-button")
        XCTAssertTrue(plan.waitToExist(timeout: 10), "The new task's composer shows the Plan mode button.")
        XCTAssertEqual(plan.value as? String, "Off")
        assertShortcutHelpText(for: plan, equals: "Plan before making changes (⇧⌘P)")
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil({ plan.value as? String == "On" }, timeout: 5), "Shift-Command-P turns Plan mode on.")
        attachScreenshot(named: "Shift-Command-P turned Plan mode on")
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil({ plan.value as? String == "Off" }, timeout: 5), "Shift-Command-P turns it off again.")

        let addRepository = element("add-conversation-repository-button")
        XCTAssertTrue(addRepository.waitToExist(timeout: 5))
        assertShortcutHelpText(for: addRepository, equals: "Add a repository (⇧⌘R)")
        app.typeKey("r", modifierFlags: [.command, .shift])
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitToExist(timeout: 5), "Shift-Command-R opens the Add repository picker.")
        attachScreenshot(named: "Shift-Command-R opened the repository picker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !repositorySearch.exists }, timeout: 5), "Escape closes the picker.")

        // A native button whose shortcut is the window's default action names Return.
        _ = openScheduleHint()
        assertShortcutHelpText(for: element("schedule-done-button"), equals: "Use this schedule; Send then schedules the task (Return)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(element("schedule-hint")), "Escape closes the schedule hint.")

        let hideSidebar = element("hide-task-sidebar-button")
        XCTAssertTrue(hideSidebar.waitToExist(timeout: 5), "The task opens with its sidebar shown.")
        assertShortcutHelpText(for: hideSidebar, equals: "Hide sidebar (⌃⌘S)")
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 5), "Control-Command-S hides the sidebar to its rail.")
        attachScreenshot(named: "Control-Command-S hid the task sidebar")
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(element("task-sidebar").waitToExist(timeout: 5), "Control-Command-S shows it again.")

        let skills = element("open-skills-button")
        assertShortcutHelpText(for: skills, equals: "Skills, Rules & MCP (⇧⌘K)")
        // From a focused composer, whose editor would otherwise keep Escape from the page.
        let composer = element("message-composer")
        composer.click()
        app.typeKey("k", modifierFlags: [.command, .shift])
        let skillsClose = element("skills-back-button")
        XCTAssertTrue(skillsClose.waitToExist(timeout: 10), "Shift-Command-K opens the Skills page.")
        // The Button atom names its cancel shortcut, Escape, after the hint's own text.
        assertShortcutHelpText(for: skillsClose, equals: "Close (Esc)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(skillsClose), "Escape closes the Skills page.")
        app.typeText("q")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "q" }, timeout: 5), "After the Skills page closes, typing still goes to the composer.")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5))

        assertShortcutHelpText(for: back, equals: "Back to Kanban (⌘[)")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(newTask.waitToExist(timeout: 10), "Command-[ returns to the board.")
        XCTAssertFalse(back.exists)

        openTask(named: "Shortcut work")
        let terminalToggle = element("toggle-terminal-button")
        XCTAssertTrue(waitUntil({ terminalToggle.exists && terminalToggle.isEnabled }, timeout: 15), "The task's worktree lets its terminal open.")
        assertShortcutHelpText(for: terminalToggle, equals: "Open a terminal in this task's worktree (⌃`)")
        app.typeKey("`", modifierFlags: .control)
        let terminal = element("task-terminal-view")
        XCTAssertTrue(terminal.waitToExist(timeout: 10), "Control-` opens the terminal.")
        attachScreenshot(named: "Control-backtick opened the terminal")
        // From inside the shell too: the terminal doesn't keep the key for itself.
        terminal.click()
        app.typeKey("`", modifierFlags: .control)
        XCTAssertTrue(waitForDisappearance(element("task-terminal-panel")), "Control-` hides the terminal while it has focus.")

        sendFromComposer("Hold until stopped by a shortcut.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20), "The turn is running.")
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.exists && stop.isEnabled }, timeout: 20), "The composer offers Stop while the turn runs.")
        assertShortcutHelpText(for: stop, equals: "Pause Codex response (⌘.)")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10), "Command-. stops the turn.")
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 15), "The stopped turn offers Continue.")
        XCTAssertTrue(waitForStatus(workTaskID, "Waiting Response"))
        for marker in [ready, received, release] { try? FileManager.default.removeItem(at: marker) }

        clickPluginsMenuItem("Plugin Catalog")
        catalogSidebarRow("plugin-catalog-atom-Button").click()
        let pressCount = element("button-press-count")
        XCTAssertTrue(pressCount.waitToExist(timeout: 10), "The catalog shows the Button page.")
        XCTAssertEqual(pluginText(pressCount), "Pressed 0 times")
        let shortcutButton = element("button-shortcut")
        XCTAssertTrue(shortcutButton.exists, "The Button page shows its Shortcut button.")
        assertShortcutHelpText(for: shortcutButton, equals: "Shift-Command-B presses it (⇧⌘B)")
        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil({ self.pluginText(pressCount) == "Pressed 1 times" }, timeout: 5), "Shift-Command-B presses the Shortcut button, which runs its onPress.")

        // Last, back on the board: the open chat widens the window past the VM's screen, and it
        // stays that wide once the chat closes, which would push later controls off screen.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(pressCount), "Command-W closes the Plugin Catalog.")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(newTask.waitToExist(timeout: 10), "Command-[ returns the main window to the board.")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 15), "Shift-Command-C opens the standalone chat.")
        attachScreenshot(named: "Shift-Command-C opened the standalone chat")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil({ !self.element("chat-sidebar").exists }, timeout: 5), "Shift-Command-C closes it again.")
    }

    /// Hovers `element` until its tooltip shows the hint's words, requires the tooltip to draw the
    /// exact hint, keys and modifiers included, keeps a close-up of the button with its tooltip,
    /// then moves away so the tooltip closes. The tooltip's help tag carries no text in the VM,
    /// OCR misreads ⌘ ⇧ ⌃ (as "96", "H", "8" or nothing), and the runner may not use the
    /// Accessibility API, so the exact text is checked by drawing it in the tooltip font and
    /// comparing its ink with the tooltip's: a missing, extra or different key changes the shape.
    private func assertShortcutHelpText(for element: XCUIElement, equals help: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = help.range(of: " (", options: .backwards).map { String(help[..<$0.lowerBound]) } ?? help
        let tooltip = app.descendants(matching: .helpTag).firstMatch
        assertNativeHelpText(for: element, equals: help, until: { self.helpTag(tooltip, shows: label) })
        if let match = tooltipInk(tooltip, against: help) {
            let (drawn, expected, overlap, covered) = match
            XCTAssertTrue(abs(drawn.width - expected.width) <= 1 && abs(drawn.height - expected.height) <= 1 && overlap >= 0.85 && covered >= 0.998,
                          "The tooltip should read exactly ‘\(help)’, shortcut included: its text is \(drawn.width)×\(drawn.height) px against \(expected.width)×\(expected.height), overlapping \(overlap), within a pixel \(covered).",
                          file: file, line: line)
        } else {
            XCTFail("The tooltip ‘\(help)’ should be on screen to compare.", file: file, line: line)
        }
        attachRegionScreenshot(tooltip.exists ? [element, tooltip] : [element], named: "Hover hint: \(help)", padding: 16)
        movePointerToHelpRunway(below: element)
        if !waitUntil({ !tooltip.exists }, timeout: 4) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.85)).hover()
        }
        XCTAssertTrue(waitUntil({ !tooltip.exists }, timeout: 8), "Moving away should close the tooltip ‘\(help)’.", file: file, line: line)
    }

    /// Whether the help tag is on screen and its own frame reads `label`.
    private func helpTag(_ tooltip: XCUIElement, shows label: String) -> Bool {
        guard let image = tooltipImage(tooltip, inset: -4)?.0 else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let words = Self.words((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
        return words.hasPrefix(Self.words(label))
    }

    /// The on-screen help tag, grown by `inset` points (negative grows it), at native pixels,
    /// with the screen's pixels per point.
    private func tooltipImage(_ tooltip: XCUIElement, inset: CGFloat) -> (CGImage, CGFloat)? {
        guard tooltip.exists else { return nil }
        let region = tooltip.frame.insetBy(dx: inset, dy: inset)
        guard let image = XCUIScreen.main.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main?.frame, screen.width > 0, !region.isEmpty else { return nil }
        let scale = CGFloat(image.width) / screen.width
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        return image.cropping(to: pixels).map { ($0, scale) }
    }

    /// The tooltip's text ink and `text`'s, drawn in the system tooltip font at the screen's
    /// density, compared at the best of a few one- or two-pixel shifts. `overlap` is shared ink
    /// over all ink; `covered` is the smaller share of either's ink that has the other's within a
    /// pixel. The reference is drawn in the tooltip's own polarity, since light-on-dark and
    /// dark-on-light text antialias to different stroke weights. Measured in the VM, the right
    /// hint scores covered 1.0 (overlap 0.90 to 0.98, lower in a light window), while one wrong
    /// key or modifier stays at or below covered 0.992, and mostly changes the width too. Nil when the tooltip is not on screen. Inside its border
    /// only, so the frame does not count as text.
    private func tooltipInk(_ tooltip: XCUIElement, against text: String) -> (drawn: TextInk, expected: TextInk, overlap: Double, covered: Double)? {
        guard let captured = tooltipImage(tooltip, inset: 1), let drawn = TextInk(captured.0) else { return nil }
        let scale = captured.1
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.toolTipsFont(ofSize: 0), .foregroundColor: drawn.isLightText ? NSColor.white : NSColor.black,
        ])
        let size = string.size()
        let width = Int((size.width + 16) * scale), height = Int((size.height + 8) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: drawn.isLightText ? 0.12 : 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: NSPoint(x: 8, y: 4))
        NSGraphicsContext.restoreGraphicsState()
        guard let reference = context.makeImage(), let expected = TextInk(reference) else { return nil }
        // The tooltip's text can sit a pixel off the reference's, which antialiasing turns into a
        // different ink edge, so take the best of the small shifts.
        var bestOverlap = 0.0, bestCovered = 0.0
        for dy in -1...1 {
            for dx in -2...2 {
                var shared = 0, either = 0, drawnNear = 0, drawnInk = 0, expectedNear = 0, expectedInk = 0
                for y in -1...max(drawn.height, expected.height) {
                    for x in -2...max(drawn.width, expected.width) + 2 {
                        let a = drawn.isInk(x, y), b = expected.isInk(x + dx, y + dy)
                        if a && b { shared += 1 }
                        if a || b { either += 1 }
                        if a { drawnInk += 1; if expected.hasInk(near: x + dx, y + dy) { drawnNear += 1 } }
                        if b { expectedInk += 1; if drawn.hasInk(near: x, y) { expectedNear += 1 } }
                    }
                }
                bestOverlap = max(bestOverlap, Double(shared) / Double(max(either, 1)))
                bestCovered = max(bestCovered, min(Double(drawnNear) / Double(max(drawnInk, 1)), Double(expectedNear) / Double(max(expectedInk, 1))))
            }
        }
        return (drawn, expected, bestOverlap, bestCovered)
    }
}

/// The text pixels of an image of text on a plain background, cropped to their bounds. Text is
/// whichever side of mid-grey the background (the median pixel) is not, so light and dark
/// tooltips both work.
private struct TextInk {
    let width: Int
    let height: Int
    /// Whether the text is lighter than its background.
    let isLightText: Bool
    private let ink: [Bool]

    init?(_ image: CGImage) {
        let fullWidth = image.width, fullHeight = image.height
        var pixels = [UInt8](repeating: 0, count: fullWidth * fullHeight)
        guard let context = CGContext(data: &pixels, width: fullWidth, height: fullHeight, bitsPerComponent: 8, bytesPerRow: fullWidth,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        let lightText = pixels.sorted()[pixels.count / 2] < 128
        isLightText = lightText
        let isInk = pixels.map { lightText ? $0 > 128 : $0 < 128 }
        var minX = fullWidth, maxX = -1, minY = fullHeight, maxY = -1
        for y in 0..<fullHeight {
            for x in 0..<fullWidth where isInk[y * fullWidth + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        width = maxX - minX + 1
        height = maxY - minY + 1
        ink = (minY...maxY).flatMap { y in (minX...maxX).map { x in isInk[y * fullWidth + x] } }
    }

    func isInk(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height && ink[y * width + x]
    }

    func hasInk(near x: Int, _ y: Int) -> Bool {
        (-1...1).contains { dy in (-1...1).contains { dx in isInk(x + dx, y + dy) } }
    }
}

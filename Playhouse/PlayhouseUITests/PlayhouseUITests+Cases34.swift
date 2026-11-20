import AppKit
import Foundation
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

    // case-contract: test_markdown_atom_renders_formatted_markdown | The Plugin Catalog lists the Markdown atom, whose page renders Markdown atoms into formatted native text with no plugin error: its skill sample shows its frontmatter as a table of its entries (release-notes) with no raw --- fences, a heading without its # marks that is taller than the body text, a paragraph whose bold, italic and inline code show without their markers, bullet and numbered list items, a quote, a Swift code block card, a table with its cells and the text after a rule; a Markdown whose frontmatter is hide shows only its body, and a Markdown given raw string children renders them as Markdown (a heading without its ## marks). `plugin render` reports a Markdown atom from its text prop or from its string children with no errors and its props as given, while a frontmatter other than table or hide, a mistyped size or selectable, an atom child, or an event the atom doesn't raise is reported in errors with exit 1.
    func test_markdown_atom_renders_formatted_markdown() throws {
        launchApp(defaultParent: fixture.parent.path)
        clickPluginsMenuItem("Plugin Catalog")
        let row = catalogSidebarRow("plugin-catalog-atom-Markdown")
        XCTAssertTrue(row.waitToExist(timeout: 15), "The Plugin Catalog lists the Markdown atom.")
        row.click()
        let skill = element("markdown-skill")
        XCTAssertTrue(skill.waitToExist(timeout: 10), "The Markdown page renders its atoms.")
        XCTAssertFalse(element("plugin-error").exists, "The Markdown page renders without a plugin error.")
        XCTAssertTrue(element("markdown-skill-frontmatter").staticTexts["release-notes"].exists, "The frontmatter shows as a table of its entries.")
        XCTAssertFalse(skill.staticTexts["---"].exists, "The raw frontmatter fences don't show.")
        let heading = skill.staticTexts["Release notes"]
        XCTAssertTrue(heading.exists, "The heading shows without its # marks.")
        XCTAssertFalse(skill.staticTexts["# Release notes"].exists, "The heading's marks don't show.")
        XCTAssertTrue(skill.staticTexts["Summarize merged changes from git log, briefly."].exists,
                      "Bold, italic and inline code show without their markers.")
        let item = skill.staticTexts["Group changes by area."]
        XCTAssertTrue(item.exists, "A bullet list item renders.")
        XCTAssertGreaterThan(heading.frame.height, item.frame.height, "The heading is larger than the body text.")
        XCTAssertTrue(skill.staticTexts["Collect the changes"].exists, "A numbered list item renders.")
        XCTAssertTrue(skill.staticTexts["Keep it short."].exists, "A quote renders without its > mark.")
        XCTAssertTrue(skill.staticTexts["Swift"].exists, "A fenced block shows as a code card named for its language.")
        XCTAssertTrue(skill.staticTexts["Area"].exists && skill.staticTexts["App"].exists, "A table shows its header and cells.")
        XCTAssertTrue(skill.staticTexts["The end."].exists, "The text after a rule renders.")
        let hidden = element("markdown-hidden-frontmatter")
        XCTAssertTrue(hidden.staticTexts["Only the body shows."].exists, "A Markdown with frontmatter hide shows its body.")
        XCTAssertFalse(hidden.staticTexts["hidden"].exists || element("markdown-hidden-frontmatter-frontmatter").exists, "Hidden frontmatter doesn't show.")
        XCTAssertTrue(element("markdown-children").staticTexts["From string children"].exists, "Raw string children render as Markdown.")
        attachScreenshot(named: "The Markdown atom renders formatted Markdown")
        let capture = XCTAttachment(screenshot: skill.screenshot())
        capture.name = "The Markdown atom's skill sample"
        capture.lifetime = .keepAlways
        add(capture)

        let page = try XCTUnwrap(try runCLI(["plugin", "render", "--page", "Markdown"])["result"] as? [String: Any])
        XCTAssertEqual((page["errors"] as? [String])?.isEmpty, true, "The Markdown catalog page renders without errors: \(page)")
        let tree = try XCTUnwrap(page["tree"] as? [String: Any])
        let skillProps = try XCTUnwrap(markdownNode("markdown-skill", in: tree)?["props"] as? [String: Any])
        XCTAssertEqual(skillProps["frontmatter"] as? String, "table")
        XCTAssertEqual(skillProps["selectable"] as? Bool, true)
        XCTAssertTrue((skillProps["text"] as? String)?.hasPrefix("---\nname: release-notes\n") == true)
        let hiddenProps = try XCTUnwrap(markdownNode("markdown-hidden-frontmatter", in: tree)?["props"] as? [String: Any])
        XCTAssertEqual(hiddenProps["frontmatter"] as? String, "hide")
        XCTAssertEqual(hiddenProps["size"] as? Double, 11)
        XCTAssertEqual(hiddenProps["color"] as? String, "secondary")
        let childrenNode = try XCTUnwrap(markdownNode("markdown-children", in: tree))
        XCTAssertEqual(childrenNode["type"] as? String, "Markdown")
        XCTAssertEqual(markdownStrings(childrenNode), "## From string children\nA Markdown atom also reads its raw strings.",
                       "A Markdown's raw string children are its source.")

        let rendered = try renderMarkdownPlugin(##"Playhouse.render(h(Markdown, { text: "# Title\n**bold** and `code`", size: 14, testID: "doc" }));"##)
        XCTAssertEqual((rendered["errors"] as? [String])?.isEmpty, true, "A plugin renders a Markdown atom from its text prop: \(rendered)")
        let doc = try XCTUnwrap(markdownNode("doc", in: try XCTUnwrap(rendered["tree"] as? [String: Any])))
        XCTAssertEqual(doc["type"] as? String, "Markdown")
        XCTAssertEqual((doc["props"] as? [String: Any])?["text"] as? String, "# Title\n**bold** and `code`")
        XCTAssertEqual((doc["props"] as? [String: Any])?["size"] as? Double, 14)
        let fromStrings = try renderMarkdownPlugin(#"Playhouse.render(h(Markdown, { testID: "doc" }, "- one\n", "- two"));"#)
        XCTAssertEqual((fromStrings["errors"] as? [String])?.isEmpty, true, "A plugin renders a Markdown atom from string children: \(fromStrings)")
        XCTAssertEqual(markdownStrings(try XCTUnwrap(markdownNode("doc", in: try XCTUnwrap(fromStrings["tree"] as? [String: Any])))), "- one\n- two")

        for (source, message) in [
            (#"Playhouse.render(h(Markdown, { frontmatter: "show" }, "x"));"#, #"<Markdown> has an invalid prop: frontmatter: expected "table" or "hide", found "show""#),
            (#"Playhouse.render(h(Markdown, { size: "large" }, "x"));"#, "<Markdown> has an invalid prop: size: expected a number, found a string"),
            (#"Playhouse.render(h(Markdown, { selectable: "yes" }, "x"));"#, "<Markdown> has an invalid prop: selectable: expected a boolean, found a string"),
            (#"Playhouse.render(h(Markdown, null, h(Text, null, "x")));"#, "<Markdown> can't hold <Text>"),
            (#"Playhouse.render(h(Markdown, { onLink: function () {} }, "x"));"#, #"<Markdown> has no event "onLink""#),
        ] {
            let failed = try renderMarkdownPlugin(source, expectedStatus: 1)
            XCTAssertTrue((failed["errors"] as? [String] ?? []).contains { $0.contains(message) }, "\(source) reports \(message): \(failed)")
        }
    }

    func renderMarkdownPlugin(_ source: String, expectedStatus: Int32 = 0) throws -> [String: Any] {
        let file = dataDirectory.appendingPathComponent("plugin-markdown-\(UUID().uuidString.prefix(8)).js")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return try XCTUnwrap(try runCLI(["plugin", "render", "--file", file.path], expectedStatus: expectedStatus)["result"] as? [String: Any])
    }

    func markdownNode(_ testID: String, in tree: [String: Any]) -> [String: Any]? {
        if (tree["props"] as? [String: Any])?["testID"] as? String == testID { return tree }
        for child in tree["children"] as? [[String: Any]] ?? [] {
            if let found = markdownNode(testID, in: child) { return found }
        }
        return nil
    }

    func markdownStrings(_ node: [String: Any]) -> String {
        (node["children"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "#text" }.compactMap { $0["text"] as? String }.joined()
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
}

extension PlayhouseUITests {
    // case-contract: test_conversation_open_reads_reconciled_history_and_shows_loading | Opening a task reads its newest history page and the task as that read reconciled it in one request: conversation history --include-task returns the task record beside the messages, which a plain read leaves out, so a submitted prompt whose turn never started comes back from that read as Waiting Response with the prompt in its saved draft, while a task that doesn't exist fails as not found with no record. While the opening read hasn't answered (held by PLAYHOUSE_E2E_HISTORY_READ_DELAY_SECONDS), the transcript shows Loading conversation… and never the empty conversation prompt; once it answers the stored messages replace the loading state, and a task with no messages shows its empty conversation prompt only then. A brand-new task shows its empty state at once, never the loading state, and the standalone chat opens through the same read: its opening read returns the chat beside its messages, and the chat shows the loading state until they arrive. Opening is shared presentation over one daemon read, so one representative provider (Codex) covers it.
    func test_conversation_open_reads_reconciled_history_and_shows_loading() throws {
        // The success fixture answers a turn without asking questions, so a CLI send returns.
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success").path
        // Every history read the window makes is held, so what it shows until one answers stays in view.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ["PLAYHOUSE_E2E_HISTORY_READ_DELAY_SECONDS": "8"])
        let loading = element("conversation-history-loading")
        let empty = element("empty-conversation")
        // A brand-new task has nothing to load: it shows its empty state at once.
        element("new-task-button").click()
        XCTAssertTrue(empty.waitToExist(timeout: 4), "A new task shows its empty state without waiting for the held read.")
        XCTAssertFalse(loading.exists, "A new task never shows the loading state.")
        attachScreenshot(named: "A new task shows its empty state at once, never the loading state")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))

        let title = "Opened history"
        try createTaskFixture(title: title, roots: [fixture.primary.path])
        let taskID = try self.taskID(named: title)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Say hello."])
        let plain = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertNil(plain["task"], "A plain read returns only the conversation.")
        let reply = try XCTUnwrap((plain["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "assistant" }?["text"] as? String)
        let opened = try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "80", "--defer-images", "--include-task"])["result"] as? [String: Any])
        XCTAssertEqual((opened["task"] as? [String: Any])?["id"] as? String, taskID, "The read returns the task beside its messages.")
        XCTAssertEqual((opened["task"] as? [String: Any])?["status"] as? String, try taskRecord(id: taskID)?["status"] as? String)

        func open(_ title: String) {
            let card = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(card.waitToExist(timeout: 10), "Task card is missing: \(title)")
            clickTaskCardTitle(card)
            XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10), "Clicking the task card title should open the task.")
        }
        func showsLoading(_ context: String) {
            XCTAssertTrue(loading.waitToExist(timeout: 4), "\(context): the transcript shows that it is loading until the history read answers.")
            XCTAssertFalse(empty.exists, "\(context): a conversation that is still loading never claims to be empty.")
            attachScreenshot(named: "\(context): a held history read shows Loading conversation, not the empty state")
            attachElementScreenshot(loading, named: "\(context): the loading state")
            XCTAssertTrue(loading.exists, "\(context): the screenshots were taken while the read was still held.")
        }
        open(title)
        showsLoading("Task")
        XCTAssertEqual(element("conversation-scroll-view").value as? String, "Loading conversation history")
        let replyRow = transcriptMessage(reply)
        XCTAssertTrue(replyRow.waitToExist(timeout: 20), "The stored messages replace the loading state.")
        XCTAssertFalse(loading.exists, "The loading state is gone once the messages are in.")
        XCTAssertFalse(empty.exists)
        attachScreenshot(named: "The stored messages replace the loading state")

        // A task with no messages loads too, and shows its empty state only once it has.
        let neverStarted = "Opened never-started prompt"
        try createTaskFixture(title: neverStarted, roots: [fixture.primary.path])
        let neverStartedID = try self.taskID(named: neverStarted)
        let submitted = "Submitted before Playhouse restarted."
        _ = try runCLI(["task", "draft", neverStartedID, "--text", ""])
        _ = try runCLI(["task", "prompt", neverStartedID, "--text", submitted, "--status", "In Progress", "--submitted", "true"])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        open(neverStarted)
        showsLoading("Empty task")
        XCTAssertTrue(empty.waitToExist(timeout: 20), "Once the read answers with no messages, the empty state shows.")
        XCTAssertFalse(loading.exists)
        // The record that read reconciled restores the never-started prompt to the composer.
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == submitted }, timeout: 10), "The reconciled record returns the never-started prompt to the composer.")
        XCTAssertEqual(try taskRecord(id: neverStartedID)?["status"] as? String, "Waiting Response")
        let reopened = try XCTUnwrap(try runCLI(["conversation", "history", neverStartedID, "--include-task"])["result"] as? [String: Any])
        XCTAssertEqual((reopened["messages"] as? [Any])?.count, 0)
        XCTAssertEqual((reopened["task"] as? [String: Any])?["status"] as? String, "Waiting Response")
        XCTAssertEqual((reopened["task"] as? [String: Any])?["savedPrompt"] as? String, submitted)
        // Opening a task that doesn't exist fails without a task record.
        let missing = try runCLI(["conversation", "history", "A8AC713C-BDD7-4B54-9B4A-6D6CCD7F957C", "--include-task"], expectedStatus: 3)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")
        XCTAssertNil(missing["result"], "A failed opening read returns no task.")
        attachScreenshot(named: "An empty conversation shows its empty state once loaded")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))

        // The standalone chat opens through the same read.
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", chatID, "--message", "Say hello in the chat."])
        let chat = try XCTUnwrap(try runCLI(["conversation", "history", chatID, "--include-task"])["result"] as? [String: Any])
        XCTAssertEqual((chat["task"] as? [String: Any])?["id"] as? String, chatID, "A chat's opening read returns the chat beside its messages.")
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        showsLoading("Standalone chat")
        XCTAssertTrue(transcriptMessage("Say hello in the chat.").waitToExist(timeout: 20), "The chat's stored messages replace the loading state.")
        XCTAssertFalse(loading.exists)
        XCTAssertFalse(empty.exists, "A chat with messages never shows its empty state.")
        attachScreenshot(named: "The standalone chat's messages replace the loading state")
    }
}

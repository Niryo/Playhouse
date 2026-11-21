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
    // case-contract: test_claude_pending_question_recovers_after_provider_process_restarts | Claude's pending AskUserQuestion is persisted and restored from fresh CLI/XPC history after the provider turn ends; the task remains Waiting Response while unanswered, and answering resumes the saved Claude session in In Progress, delivers the answer, stores and shows the prompt that carried it as sent, clears pending state, and returns to Waiting Response. While the recovery turn applying the answer runs, the answered question is no longer pending in history or shown in the reopened conversation, which still shows the question that started it, and the task is In Progress; if that recovery dies mid-turn, the question returns for retry with the task in Waiting Response, and answering again succeeds.
    func test_claude_pending_question_recovers_after_provider_process_restarts() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-restart-question")
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
            "task", "create", "--title", "Restart-safe Claude question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Restart-safe Claude question")
        element("message-composer").click()
        element("message-composer").typeText("Ask a restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Restart-safe Claude question", inColumn: "Waiting Response")
        openTask(named: "Restart-safe Claude question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10), "Reopening should restore the pending question.")

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12), "Playhouse should finish its bounded shutdown before relaunch.")
        relaunchApp()
        openTask(named: "Restart-safe Claude question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10), "The saved question should return after the app and provider process restart.")
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Restart-safe Claude question", inColumn: "Waiting Response")
        openTask(named: "Restart-safe Claude question")
        let recoveryPause = URL(fileURLWithPath: executable.path + ".recovery-pause")
        let recoveryReady = URL(fileURLWithPath: executable.path + ".recovery-ready")
        let recoveryRelease = URL(fileURLWithPath: executable.path + ".recovery-release")
        try "Hold the recovery turn open.\n".write(to: recoveryPause, atomically: true, encoding: .utf8)
        defer { try? "Release after assertion failure.\n".write(to: recoveryRelease, atomically: true, encoding: .utf8) }
        selectQuestionOption(identifier: "ai-question-option-question-1-Green")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: recoveryReady.path) }, timeout: 15),
                      "The fixture should hold the recovery turn open.")
        XCTAssertTrue(waitUntil({ !self.element("conversation-user-input-request").exists }, timeout: 5),
                      "The answered question card should leave while its recovery turn runs.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        attachScreenshot(named: "Answered question card hidden while its recovery turn runs")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        openTask(named: "Restart-safe Claude question")
        // The prompt that carries the answer is stored and shown as sent.
        XCTAssertTrue(waitUntil({ self.transcriptContains("Answer: Green") }, timeout: 10),
                      "The reopened conversation should load its saved history, with the answer's prompt as sent.")
        XCTAssertTrue(transcriptContains("Ask a restart-safe structured question."),
                      "Reopening mid-recovery must still show the conversation the recovery continues.")
        XCTAssertFalse(transcriptContains("[Private answer sent after restart]"),
                       "The prompt shown as sent is not repeated as a pending stand-in bubble.")
        XCTAssertFalse(waitUntil({ self.element("conversation-user-input-request").exists }, timeout: 2),
                       "Reopening the task mid-recovery must not bring back the answered question.")
        let applyingHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertNil(applyingHistory["pendingUserInputRequest"] as? [String: Any])
        XCTAssertFalse(transcriptContains("Recovered answer: Green."))
        attachScreenshot(named: "Reopened task mid-recovery keeps the answered question hidden")

        // The recovery's Claude Code process dies mid-turn (agents outlive a daemon restart, so
        // killing the daemon would not end it); the question must come back for retry.
        let recoveryTurn = try XCTUnwrap(try diagnosticEvents().last { $0["event"] as? String == "claude.turn.started" })
        let recoveryPID = try XCTUnwrap((recoveryTurn["claudePID"] as? String).flatMap { pid_t($0) })
        XCTAssertEqual(kill(recoveryPID, SIGKILL), 0, "The test should stop the Claude Code process running the recovery turn.")
        XCTAssertTrue(waitUntil({ kill(recoveryPID, 0) != 0 }, timeout: 5), "The killed recovery process should exit.")
        for marker in [recoveryPause, recoveryReady] {
            try? FileManager.default.removeItem(at: marker)
        }
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15),
                      "A failed recovery should restore its question card in the open window.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        openTask(named: "Restart-safe Claude question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10),
                      "A recovery interrupted mid-turn should show its question again after reopening.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        attachScreenshot(named: "Question returns for retry after the recovery dies mid-turn")
        selectQuestionOption(identifier: "ai-question-option-question-1-Green")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ self.transcriptContains("Recovered answer: Green.") }, timeout: 15))
        XCTAssertFalse(element("conversation-user-input-request").exists)
        XCTAssertTrue(transcriptContains("Question: Which color should I use?"), "The retried answer's prompt is shown as sent.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        attachScreenshot(named: "Retried answer applied and the question cleared")
    }
    // case-contract: test_claude_pending_plan_mode_question_recovers_in_plan_mode | A Claude AskUserQuestion asked during a Plan mode turn persists its mode; after its provider process ends, answering resumes the saved Claude session in Plan mode rather than silently downgrading to Code mode, relaunching the recovery turn with --permission-mode plan.
    func test_claude_pending_plan_mode_question_recovers_in_plan_mode() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-restart-plan-question")
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
            "task", "create", "--title", "Restart-safe Claude plan question", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Restart-safe Claude plan question")
        setPlanMode(true)
        element("message-composer").click()
        element("message-composer").typeText("Ask a restart-safe structured question.")
        element("send-message-button").click()
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12), "Playhouse should finish its bounded shutdown before relaunch.")
        relaunchApp()
        openTask(named: "Restart-safe Claude plan question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 10), "The saved question should return after the app and provider process restart.")
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        selectQuestionOption(identifier: "ai-question-option-question-1-Green")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ self.transcriptContains("Recovered answer: Green.") }, timeout: 15))
        XCTAssertFalse(element("conversation-user-input-request").exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")

        let recoveryHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any])
        let recoveryArguments = try XCTUnwrap((recoveryHistory["turns"] as? [[String: Any]])?.last?["arguments"] as? [String])
        let permissionModeIndex = try XCTUnwrap(
            recoveryArguments.firstIndex(of: "--permission-mode"),
            "The recovered turn must relaunch Claude with an explicit permission mode."
        )
        XCTAssertEqual(
            recoveryArguments[permissionModeIndex + 1],
            "plan",
            "The recovered turn must continue in Plan mode, not silently downgrade to Code mode."
        )
    }
    // case-contract: test_claude_background_agent_keeps_turn_open_until_resolved | A Claude background Agent/Task call renders a live subagent activity that stays in progress through its launch confirmation and intermediate progress, resolves only once its real completion notification arrives, and keeps the turn open until then instead of settling early. A status-only completion update is not shown as an agent result; the summary-bearing notification is persisted as one normal assistant message in the parent conversation, appears in the visible transcript as the agent's row (named, finished working, with an arrow) rather than a reply bubble, opens the report in the read-only agent window when clicked, and survives fresh CLI/XPC history reads and app reopening without duplication. The agent's window, opened while it runs and again after it finishes, also shows its own work read from its Claude Code sidechain file (found by the meta file naming the launching tool use): its prompt without Claude Code's own reminders, its text, and its tool calls with their input and output, each after the text it followed, ending with its report once as the final answer only after it finishes; a window left open on the running agent updates with that report when the agent finishes, without reopening it. A failed background agent remains inspectable as a failed activity, and its error summary is not added as an assistant result. When a background agent's notification wakes the parent after its result, the turn stays open through that resumed work, including when the last agent finishes while the woken parent is still streaming, and ends only with the parent's next result, keeping its final answer and both agent reports. A failed agent whose notification the running turn already consumed ends the send promptly instead of waiting for a wake. The system prompt Playhouse appends for Claude lets it run shell commands and agents in the foreground or background, forbids only processes detached with & or nohup, says it can end its response while background work runs instead of waiting and must report the outcome only after the background results, and no longer tells it to sleep, keep shell commands in the foreground, or keep its turn open for work it started.
    func test_claude_background_agent_keeps_turn_open_until_resolved() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-background-agent")
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
        let summaryPause = URL(fileURLWithPath: executable.path + ".background-summary-pause")
        let summaryReady = URL(fileURLWithPath: executable.path + ".background-summary-ready")
        let summaryRelease = URL(fileURLWithPath: executable.path + ".background-summary-release")
        try "Pause after status-only completion.\n".write(to: summaryPause, atomically: true, encoding: .utf8)
        defer { try? "Release summary notification.\n".write(to: summaryRelease, atomically: true, encoding: .utf8) }
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude background agent", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        // The fixture writes the agent's own work where Claude Code keeps its session files.
        let claudeConfig = dataDirectory.appendingPathComponent("claude-config").path
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: [
            "CLAUDE_CONFIG_DIR": claudeConfig, "PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR": claudeConfig,
        ])
        openTask(named: "Claude background agent")
        element("message-composer").click()
        element("message-composer").typeText("Launch a background agent for this turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: summaryReady.path) }, timeout: 15),
                      "The fixture should pause after its status-only completion update.")

        let subagentRow = element("codex-subagent-row-toolu_background_agent")
        XCTAssertTrue(subagentRow.waitToExist(timeout: 10), "A background Agent/Task call should render a live subagent row.")
        XCTAssertTrue(subagentRow.label.contains("started working"), subagentRow.label)
        XCTAssertTrue(
            waitUntil({ self.transcriptContains("STARTED") }, timeout: 10),
            "The parent response should be visible while the background summary notification is still pending."
        )
        XCTAssertEqual(
            try taskRecord(id: taskID)?["status"] as? String,
            "In Progress",
            "The parent task must remain active after Claude returns its result but before the background summary notification."
        )
        let reportIdentifier = "agent-report-row-toolu_background_agent"
        XCTAssertFalse(element(reportIdentifier).exists, "A status-only completion must not render progress text as the agent result.")
        // The running agent's window shows its own work so far, read from its sidechain file.
        subagentRow.descendants(matching: .any).matching(identifier: "subagent-row-chevron").firstMatch.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitToExist(timeout: 5), "The running agent's arrow should open its window.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("check something") }, timeout: 10),
                      "The running agent's window should show the prompt it was given.")
        XCTAssertTrue(transcriptContains("Checking the fixture README first."), "The running agent's window should show its text.")
        XCTAssertFalse(transcriptContains("Fixture reminder"), "Claude Code's own reminders are not part of the agent's work.")
        let agentToolCall = element("conversation-tool-call-toolu_bg_sub_read")
        XCTAssertTrue(agentToolCall.waitToExist(timeout: 5), "The running agent's window should show its tool calls.")
        XCTAssertFalse(transcriptContains("Background check finished."), "The report is not shown before the agent finishes.")
        let agentText = element("assistant-message-msg_bg_sub_1-0")
        XCTAssertTrue(agentText.exists, "The agent's text renders as its own message.")
        XCTAssertGreaterThanOrEqual(agentToolCall.frame.minY, agentText.frame.maxY - 1, "The agent's tool call sits after the text it followed.")
        // The agent's shell call collapses to its command; expanding shows its purpose, input and output.
        let agentToolCommand = element("conversation-tool-call-command-toolu_bg_sub_read")
        XCTAssertTrue([agentToolCommand.label, agentToolCommand.value as? String ?? ""].joined(separator: " ").contains("cat README.md"),
                      "The collapsed agent tool call shows the start of its command.")
        element("conversation-tool-call-toggle-toolu_bg_sub_read").click()
        let agentToolSummary = element("conversation-tool-call-summary-toolu_bg_sub_read")
        XCTAssertTrue(agentToolSummary.waitToExist(timeout: 5), "Expanding the agent's tool call shows its purpose.")
        XCTAssertTrue((agentToolSummary.value as? String ?? agentToolSummary.label).hasPrefix("Read the fixture"), String(describing: agentToolSummary.value))
        XCTAssertTrue(element("conversation-tool-call-input-toolu_bg_sub_read").exists)
        XCTAssertTrue(transcriptContains("cat README.md"), "The agent's tool call shows its input.")
        XCTAssertTrue(transcriptContains("Fixture README"), "The agent's tool call shows its output.")
        XCTAssertTrue(element("conversation-tool-call-output-toolu_bg_sub_read").exists)
        attachScreenshot(named: "Claude background agent work while running")
        // The window left open on the running agent updates once it finishes, without reopening it.
        try "Release summary notification.\n".write(to: summaryRelease, atomically: true, encoding: .utf8)
        let agentReport = element("assistant-message-msg_bg_sub_2-0")
        XCTAssertTrue(agentReport.waitToExist(timeout: 15), "The open agent window should show the report once the agent finishes.")
        XCTAssertTrue(element("subagent-conversation-panel").exists, "The agent window stays open while it updates.")
        XCTAssertFalse(element("assistant-message-toolu_background_agent-report").exists,
                       "The report the agent already wrote as its last text is shown once, not added again.")
        XCTAssertLessThanOrEqual(agentToolCall.frame.maxY, agentReport.frame.minY + 1, "The report follows the agent's earlier work.")
        attachScreenshot(named: "Claude background agent window updated with its report")
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5))
        // The fixture reports no outcome, so an outcome nudge turn follows at once; each turn
        // that settles folds Worked for closed again. Expand only after everything has settled.
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response"), "The turn and its outcome nudge should settle.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 15), "The window should show the settled turn.")
        XCTAssertTrue(
            waitUntil({
                // The final answer folds agent rows into a collapsed Worked for;
                // expand only when it is actually collapsed.
                let disclosure = self.element("codex-activity-disclosure")
                if !subagentRow.exists, disclosure.exists,
                   disclosure.label.hasPrefix("Worked for"),
                   (disclosure.value as? String ?? "").hasPrefix("Collapsed") {
                    // The settled transcript can leave the disclosure scrolled under the header.
                    if self.scrollFullyIntoView(disclosure, in: self.element("conversation-scroll-view")) {
                        disclosure.click()
                    }
                }
                return self.app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier == %@ AND label CONTAINS %@", "codex-subagent-row-toolu_background_agent", "finished working"
                )).firstMatch.exists
            }, timeout: 15),
            "The row must resolve to completed only once the real notification arrives, not the launch confirmation."
        )
        let report = app.descendants(matching: .any).matching(identifier: reportIdentifier)
        XCTAssertTrue(report.firstMatch.waitToExist(timeout: 10), "The completed background-agent result should appear in the parent conversation transcript.")
        XCTAssertEqual(report.count, 1, "The result should appear exactly once in the parent conversation.")
        XCTAssertTrue(report.firstMatch.label.contains("Explore finished working"),
                      "The result should appear as the agent's row, not as a reply bubble: \(report.firstMatch.label)")
        XCTAssertFalse(element("assistant-message-claude-background-agent-result-toolu_background_agent").exists,
                       "The agent's report should not render as a parent reply bubble.")
        XCTAssertTrue(report.firstMatch.descendants(matching: .any).matching(identifier: "subagent-row-chevron").firstMatch.exists,
                      "The agent's row should show an arrow that opens it.")
        XCTAssertTrue(scrollFullyIntoView(report.firstMatch, in: element("conversation-scroll-view")))
        attachScreenshot(named: "Claude background agent report row")
        report.firstMatch.descendants(matching: .any).matching(identifier: "subagent-row-chevron").firstMatch.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitToExist(timeout: 5), "The agent row's arrow should open the agent's window.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Background check finished.") }, timeout: 10),
                      "The agent window should show the agent's report.")
        XCTAssertTrue(transcriptContains("Checking the fixture README first."), "The finished agent's window keeps its earlier work.")
        XCTAssertTrue(element("conversation-tool-call-toolu_bg_sub_read").exists, "The finished agent's window keeps its tool calls.")
        attachScreenshot(named: "Claude background agent report opened")
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5))

        let history = try XCTUnwrap(try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let activities = try XCTUnwrap(history["activities"] as? [[String: Any]])
        let activity = try XCTUnwrap(activities.first { $0["childThreadID"] as? String == "toolu_background_agent" })
        XCTAssertEqual(activity["status"] as? String, "completed")
        XCTAssertEqual(activity["backgroundTaskID"] as? String, "bgtask-fixture-1")
        let launchHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any])
        let launchArguments = try XCTUnwrap((launchHistory["turns"] as? [[String: Any]])?.first?["arguments"] as? [String])
        let systemPromptIndex = try XCTUnwrap(launchArguments.firstIndex(of: "--append-system-prompt"))
        let systemPrompt = launchArguments[systemPromptIndex + 1]
        for guidance in [
            "Never detach a process with & or nohup",
            "in the foreground or with the Bash tool's run_in_background",
            "run Agent/Task calls in the foreground or in the background",
            "you can end your response instead of waiting",
            "Report the task outcome only after you have handled every background result",
        ] {
            XCTAssertTrue(systemPrompt.contains(guidance), "Claude should be told how Playhouse handles background agents: \(guidance)")
        }
        for contradiction in ["including long sleeps", "never end your turn while work you started is still running", "Never background a shell command"] {
            XCTAssertFalse(systemPrompt.contains(contradiction), "Claude must not be told to block on background agents it launched: \(contradiction)")
        }

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 12))
        relaunchApp()
        openTask(named: "Claude background agent")
        let restoredReport = app.descendants(matching: .any).matching(identifier: reportIdentifier)
        XCTAssertTrue(restoredReport.firstMatch.waitToExist(timeout: 10), "The result should remain visible after reopening the conversation.")
        XCTAssertEqual(restoredReport.count, 1, "Reopening should not duplicate the result message.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        let failedTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude failed background agent", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let failedTaskID = try XCTUnwrap(failedTask["id"] as? String)
        openTask(named: "Claude failed background agent")
        element("message-composer").click()
        element("message-composer").typeText("Launch a background agent failure case.")
        element("send-message-button").click()
        let failedSentAt = Date()
        XCTAssertTrue(
            waitUntil({ self.transcriptContains("The background check failed.") }, timeout: 15),
            "The parent's answer should remain visible for a failed agent turn."
        )
        // The section is open while the turn runs and folds into Worked for once the
        // answer lands, so expand only when it is actually collapsed.
        let failedAgentRow = element("codex-subagent-row-toolu_background_agent")
        // Query by label rather than reading `failedAgentRow.label`: the row can be
        // missing for a moment while the section folds at turn end, and reading a
        // missing element's label is a fatal snapshot error, not a polled false.
        let failedAgentRowWithFailure = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "codex-subagent-row-toolu_background_agent", "failed"
        )).firstMatch
        var failedExpandAttempts = 0
        XCTAssertTrue(waitUntil({
            let disclosure = self.element("codex-activity-disclosure")
            if !failedAgentRow.exists, failedExpandAttempts < 3, disclosure.exists,
               (disclosure.value as? String ?? "").hasPrefix("Collapsed") {
                disclosure.click()
                failedExpandAttempts += 1
                // The toggle animates; reading the value again before it lands
                // would click a second time and fold the section back.
                _ = self.waitUntil({
                    (self.element("codex-activity-disclosure").value as? String ?? "").hasPrefix("Expanded")
                }, timeout: 2)
                return false
            }
            return failedAgentRowWithFailure.exists
        }, timeout: 15), failedAgentRow.exists ? failedAgentRow.label : "The failed agent row never appeared.")
        XCTAssertFalse(element(reportIdentifier).exists, "A failed agent summary must not appear as a successful assistant result.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20))
        XCTAssertLessThan(
            Date().timeIntervalSince(failedSentAt), 10,
            "A notification the running turn already consumed must not hold the turn open for a wake that never comes."
        )
        let failedHistory = try XCTUnwrap(try runCLI(
            ["conversation", "history", failedTaskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let failedActivities = try XCTUnwrap(failedHistory["activities"] as? [[String: Any]])
        let failedActivity = try XCTUnwrap(failedActivities.first { $0["childThreadID"] as? String == "toolu_background_agent" })
        XCTAssertEqual(failedActivity["status"] as? String, "failed")
        XCTAssertFalse((failedHistory["messages"] as? [[String: Any]] ?? []).contains { $0["phase"] as? String == "subagent_report" })

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        let wakePause = URL(fileURLWithPath: executable.path + ".background-wake-pause")
        let wakeReady = URL(fileURLWithPath: executable.path + ".background-wake-ready")
        let wakeRelease = URL(fileURLWithPath: executable.path + ".background-wake-release")
        try "Pause after the last notification arrives mid-work.\n".write(to: wakePause, atomically: true, encoding: .utf8)
        defer { try? "Release the woken parent's final answer.\n".write(to: wakeRelease, atomically: true, encoding: .utf8) }
        let wakeTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude woken parent", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let wakeTaskID = try XCTUnwrap(wakeTask["id"] as? String)
        openTask(named: "Claude woken parent")
        element("message-composer").click()
        element("message-composer").typeText("Launch background agents wake the parent.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: wakeReady.path) }, timeout: 15),
                      "The fixture should pause after the last notification arrives mid-work.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("WAKE STARTED") }, timeout: 10))
        // A fast fixture can stream its first message before the composer swaps Send for Stop.
        XCTAssertTrue(element("pause-response-button").waitToExist(timeout: 5),
                      "The composer should show Stop once the woken parent's turn is running.")
        // Settling on the stale earlier result would end the turn right after
        // the last notification; give that regression time to show.
        XCTAssertFalse(waitUntil({ !self.element("pause-response-button").exists }, timeout: 2),
                       "The woken parent's turn must stay active until its next result.")
        let wakeStopButton = element("pause-response-button")
        XCTAssertTrue(wakeStopButton.exists, "The composer should keep its Stop control visible during resumed work.")
        attachScreenshot(named: "Claude woken parent remains active with Stop available")
        attachElementScreenshot(wakeStopButton, named: "Claude woken parent Stop control")
        XCTAssertEqual(try taskRecord(id: wakeTaskID)?["status"] as? String, "In Progress")
        XCTAssertFalse(transcriptContains("WAKE FINAL"))
        try "Release the woken parent's final answer.\n".write(to: wakeRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ self.transcriptContains("WAKE FINAL") }, timeout: 15),
                      "The woken parent's final answer should appear once it sends its next result.")
        // The final answer folds the turn's commentary into Worked for; expand it.
        var wakeExpandAttempts = 0
        XCTAssertTrue(waitUntil({
            if self.transcriptContains("WAKE RESUMED") { return true }
            let disclosure = self.element("codex-activity-disclosure")
            if wakeExpandAttempts < 3, disclosure.exists, (disclosure.value as? String ?? "").hasPrefix("Collapsed") {
                disclosure.click()
                wakeExpandAttempts += 1
                // Let the animated toggle land before the value is read again.
                _ = self.waitUntil({ (disclosure.value as? String ?? "").hasPrefix("Expanded") }, timeout: 2)
            }
            return false
        }, timeout: 10), "Work the woken parent does should be visible.")
        let wakeHistory = try XCTUnwrap(try runCLI(
            ["conversation", "history", wakeTaskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let wakeMessages = wakeHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(
            wakeMessages.filter { $0["role"] as? String == "assistant" && $0["phase"] as? String != "subagent_report" }.last?["text"] as? String,
            "WAKE FINAL"
        )
        XCTAssertEqual(
            wakeMessages.filter { $0["phase"] as? String == "subagent_report" }.compactMap { $0["text"] as? String }.sorted(),
            ["Reviewer A finished.", "Reviewer B finished."]
        )
    }
    // case-contract: test_claude_background_shell_keeps_turn_open_through_wake | A Claude Bash call launched with run_in_background stays an in-progress activity after its launch confirmation and keeps the turn open after Claude's result while the shell runs, and still after the shell's notification empties the background task list, until the parent turn Claude Code wakes to deliver that notification sends its own result. The woken turn's answer is the final answer, the outcome it reports moves the task to Review without private outcome reminders, and the shell's completion resolves its activity with the command status without becoming an agent report. When the shell finishes before Claude's first result, so the woken turn starts before that result arrives, the turn waits for both results.
    func test_claude_background_shell_keeps_turn_open_through_wake() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-background-shell")
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
        func stage(_ name: String) -> URL { URL(fileURLWithPath: executable.path + ".background-shell-\(name)") }
        try "Pause while the shell runs.\n".write(to: stage("running-pause"), atomically: true, encoding: .utf8)
        try "Pause before the woken turn.\n".write(to: stage("wake-pause"), atomically: true, encoding: .utf8)
        defer {
            try? "Release.\n".write(to: stage("running-release"), atomically: true, encoding: .utf8)
            try? "Release.\n".write(to: stage("wake-release"), atomically: true, encoding: .utf8)
        }
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude background shell", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude background shell")
        element("message-composer").click()
        element("message-composer").typeText("Launch a background shell for this turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: stage("running-ready").path) }, timeout: 15),
                      "The fixture should pause after Claude's result while the shell runs.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("SHELL STARTED") }, timeout: 10))
        XCTAssertTrue(element("pause-response-button").exists, "The turn must stay active while a background shell runs.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        let claudeEnvironment = ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        let running = try XCTUnwrap(try runCLI(["conversation", "history", taskID], extraEnvironment: claudeEnvironment)["result"] as? [String: Any])
        let runningShell = try XCTUnwrap((running["activities"] as? [[String: Any]])?.first { $0["id"] as? String == "toolu_background_shell" })
        XCTAssertEqual(runningShell["status"] as? String, "inProgress", "The launch confirmation must not resolve a background shell.")

        try "Finish the shell.\n".write(to: stage("running-release"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: stage("wake-ready").path) }, timeout: 15),
                      "The fixture should pause between the shell's notification and the woken turn.")
        // Settling when the background task list empties would end the turn here;
        // give that regression time to show.
        XCTAssertFalse(waitUntil({ !self.element("pause-response-button").exists }, timeout: 2),
                       "The turn must stay active until the woken turn that delivers the shell's notification reports.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        XCTAssertFalse(transcriptContains("SHELL HANDLED"))

        try "Start the woken turn.\n".write(to: stage("wake-release"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ self.transcriptContains("SHELL HANDLED") }, timeout: 15),
                      "The woken turn's answer should appear as the final answer.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 15),
                      "The outcome Claude reports in its woken turn should move the task to Review.")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID], extraEnvironment: claudeEnvironment)["result"] as? [String: Any])
        let shell = try XCTUnwrap((history["activities"] as? [[String: Any]])?.first { $0["id"] as? String == "toolu_background_shell" })
        XCTAssertEqual(shell["status"] as? String, "completed")
        XCTAssertEqual(shell["backgroundTaskID"] as? String, "bgshell-fixture-1")
        XCTAssertTrue((shell["detail"] as? String ?? "").contains("completed (exit code 0)"))
        XCTAssertNil(shell["backgroundTaskSummary"] as? String, "A shell's status line is not an agent result.")
        let messages = history["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(messages.contains { $0["phase"] as? String == "subagent_report" })
        XCTAssertEqual(messages.filter { $0["role"] as? String == "assistant" }.last?["text"] as? String, "SHELL HANDLED")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        try FileManager.default.removeItem(at: stage("running-pause"))
        try FileManager.default.removeItem(at: stage("wake-pause"))
        try "Pause between the first and the woken turn's results.\n".write(to: stage("second-result-pause"), atomically: true, encoding: .utf8)
        defer { try? "Release.\n".write(to: stage("second-result-release"), atomically: true, encoding: .utf8) }
        let early = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude early background shell", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let earlyID = try XCTUnwrap(early["id"] as? String)
        openTask(named: "Claude early background shell")
        element("message-composer").click()
        element("message-composer").typeText("Launch a background shell that finishes early.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: stage("second-result-ready").path) }, timeout: 15),
                      "The fixture should pause between the first result and the woken turn's result.")
        // The fixture reaches this pause before the window shows the turn it started, so
        // the stop button is checked only once the first turn's answer has streamed in.
        XCTAssertTrue(waitUntil({ self.transcriptContains("SHELL STARTED") }, timeout: 10))
        XCTAssertTrue(element("pause-response-button").exists, "The turn must be active once its first answer streams in.")
        XCTAssertFalse(waitUntil({ !self.element("pause-response-button").exists }, timeout: 2),
                       "The first turn's result must not end the turn while the woken turn that started before it is unfinished.")
        XCTAssertEqual(try taskRecord(id: earlyID)?["status"] as? String, "In Progress")
        try "Send the woken turn's result.\n".write(to: stage("second-result-release"), atomically: true, encoding: .utf8)
        let secondResultSentAt = Date()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: earlyID)?["status"] as? String) == "Review" }, timeout: 20),
                      "When the woken turn starts before Claude's first result, the turn must wait for both results.")
        XCTAssertLessThan(Date().timeIntervalSince(secondResultSentAt), 10,
                          "The woken turn's result should settle the turn without waiting for the wake backstop.")
        XCTAssertTrue(transcriptContains("SHELL HANDLED"))
        let earlyHistory = try XCTUnwrap(try runCLI(["conversation", "history", earlyID], extraEnvironment: claudeEnvironment)["result"] as? [String: Any])
        XCTAssertEqual(
            (earlyHistory["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "assistant" }.last?["text"] as? String,
            "SHELL HANDLED"
        )
        let recorded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any])
        XCTAssertFalse(
            (recorded["turns"] as? [[String: Any]] ?? []).contains { ($0["userText"] as? String)?.contains("previous request finished without reporting") == true },
            "An outcome reported in the woken turn must not trigger private outcome reminders."
        )
    }
    // case-contract: test_claude_nudged_turn_work_stays_in_conversation | A Claude turn answers while a background review runs, the review's notification arrives right after that answer, and the woken turn adds nothing and reports no outcome; the review's report and the answer both stay in history, the answer once and as the final answer. Playhouse's private status nudge then starts a turn that keeps working, and a message the user steers into it is kept too: its commentary, its shell call, the background suite it launches, that suite's report delivered in a notification-driven woken turn, the screenshot it presents, and its final answer are streamed and recorded in order, and the completed outcome it reports moves the task to Review. Fresh history, a paged history read, and a later ordinary turn all keep that work, with the final report as the latest message before the later turn, while the nudge prompt Playhouse sent is shown once as its own message and no placeholder replaces it.
    func test_claude_nudged_turn_work_stays_in_conversation() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-nudged-work")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "Playhouse test owns this Claude Code protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"), atomically: true, encoding: .utf8
        )
        claudeFixtureExecutable = executable.path
        let claudeEnvironment = ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        let staleAnswer = "The task review is approved. Only the UI review is still pending."
        let finalReport = "All checks passed and the screenshot is attached. The work is complete."
        let nudgedCommentary = ["Every review is approved. Running the final check.", "Starting the final suite in the background."]
        let steerReady = URL(fileURLWithPath: executable.path + ".nudged-steer-ready")
        try "Hold the nudged turn for a steer.\n".write(to: URL(fileURLWithPath: executable.path + ".nudged-steer-pause"), atomically: true, encoding: .utf8)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude nudged work", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude nudged work")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Wait for the pending UI review.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: steerReady.path) }, timeout: 40),
                      "The private nudge turn should start and wait for a steer.")
        let steerResult = try runCLI(["conversation", "steer", taskID, "--message", "Also double check the docs."], extraEnvironment: claudeEnvironment)
        XCTAssertEqual((steerResult["result"] as? [String: Any])?["accepted"] as? Bool, true, "A user can steer the running nudge turn.")

        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 40),
                      "The completed outcome reported inside the nudged turn should move the task to Review.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(finalReport) }, timeout: 15),
                      "The nudged turn's final report should appear in the visible transcript.")
        // The nudged turn's answer, with its screenshot, is taller than the viewport. A transcript that
        // followed it to the end has scrolled the earlier rows out of the lazy stack, so read them by scrolling up.
        let transcript = element("conversation-scroll-view")
        func scrollUpUntilShown(_ text: String) -> Bool {
            // The transcript reloads when the turn ends; the earlier rows are briefly absent while it re-renders.
            if waitUntil({ self.transcriptContains(text) }, timeout: 5) { return true }
            for _ in 0..<20 {
                transcript.scroll(byDeltaX: 0, deltaY: 300)
                if waitUntil({ self.transcriptContains(text) }, timeout: 1) { return true }
            }
            return false
        }
        XCTAssertTrue(scrollUpUntilShown(staleAnswer), "The earlier turn's answer should stay in the transcript.")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID], extraEnvironment: claudeEnvironment)["result"] as? [String: Any])
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        let assistant = messages.filter { $0["role"] as? String == "assistant" }.map { [($0["phase"] as? String) ?? "", ($0["text"] as? String) ?? ""] }
        XCTAssertTrue(assistant.contains(["subagent_report", "UI review approved."]),
                      "The review report that arrived right after the answer should be kept.")
        XCTAssertTrue(messages.contains { $0["role"] as? String == "user" && $0["text"] as? String == "Also double check the docs." },
                      "The steered message that joined the nudge turn should stay in the conversation.")
        XCTAssertEqual(Array(assistant.filter { $0 != ["subagent_report", "UI review approved."] }.suffix(7)), [
            ["final_answer", staleAnswer],
            ["commentary", nudgedCommentary[0]],
            ["commentary", "STEERED NUDGE: Also double check the docs."],
            ["commentary", nudgedCommentary[1]],
            ["subagent_report", "Final suite passed: all cases green."],
            ["agent_image", "Nudged turn screenshot"],
            ["final_answer", finalReport],
        ], "The nudged turn's work should be recorded in order after the stale answer.")
        XCTAssertEqual(assistant.filter { $0[1] == staleAnswer }, [["final_answer", staleAnswer]],
                       "The answer recorded before the review's report is kept once, as the final answer.")
        XCTAssertEqual(messages.last?["text"] as? String, finalReport, "The final report is the latest message.")
        let imageID = try XCTUnwrap(messages.first { $0["phase"] as? String == "agent_image" }?["id"] as? String)
        XCTAssertTrue(scrollTranscriptUntilExists(element("chat-image-\(imageID)-0")), "The screenshot the nudged turn presented should render.")
        let timeline = (history["timelineActivities"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == "toolu_nudged_check" }
        XCTAssertEqual(timeline.first?["input"] as? String, "echo NUDGED CHECK PASSED", "The nudged turn's shell call should be a timeline row.")
        XCTAssertTrue(scrollUpUntilShown("ended without reporting a task outcome"), "The nudge Playhouse sent is shown in the transcript.")
        try assertAutomaticMessageBubble(taskID: taskID, containing: "ended without reporting a task outcome")
        XCTAssertFalse(transcriptContains("Playhouse private outcome"), "No placeholder replaces the nudge.")
        attachScreenshot(named: "Claude nudged turn work follows the stale answer")
        XCTAssertTrue(expandLatestWorkedFor(), "The nudged turn's work should collapse into an expandable Worked for summary.")
        XCTAssertTrue(element("codex-activity-row-toolu_nudged_check").waitToExist(timeout: 10),
                      "The nudged turn's shell call should be listed in its Worked for details.")
        for text in nudgedCommentary {
            XCTAssertTrue(waitUntil({ self.transcriptContains(text) }, timeout: 10), "Worked for should list the nudged turn's commentary: \(text)")
        }
        XCTAssertTrue(element("agent-report-row-toolu_nudged_suite").waitToExist(timeout: 10),
                      "The background suite's report from the woken turn should render as its agent row.")
        attachScreenshot(named: "Claude nudged turn Worked for shows its call and agent report")
        let page = try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "3"], extraEnvironment: claudeEnvironment)["result"] as? [String: Any])
        XCTAssertEqual((page["messages"] as? [[String: Any]] ?? []).map { $0["text"] as? String ?? "" },
                       ["Final suite passed: all cases green.", "Nudged turn screenshot", finalReport],
                       "A paged read should end on the nudged turn's work.")

        element("back-to-board-button").click()
        assertTaskVisible("Claude nudged work", inColumn: "Review")
        attachScreenshot(named: "Claude nudged task in Review")
        openTask(named: "Claude nudged work")
        XCTAssertTrue(waitUntil({ self.transcriptContains(finalReport) }, timeout: 15), "Reopening keeps the nudged turn's final report.")
        XCTAssertTrue(element("chat-image-\(imageID)-0").waitToExist(timeout: 10), "Reopening keeps the nudged turn's screenshot.")
        // The window reopens at the question that started the turn the steer joined; the nudged
        // turn's work sits further down, after the nudge and above the steer.
        XCTAssertTrue(scrollTranscriptUntilExists(element("codex-activity-disclosure")), "Reopening shows the nudged turn's work below the nudge.")
        XCTAssertTrue(expandLatestWorkedFor(), "Reopening keeps the nudged turn's Worked for summary.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(nudgedCommentary[0]) }, timeout: 10), "Reopening keeps the nudged turn's commentary.")

        try sendLaterTurnAndAssertNudgedCallInline(taskID: taskID, callID: "toolu_nudged_check", visibleTexts: [finalReport] + nudgedCommentary)
        XCTAssertTrue(element("chat-image-\(imageID)-0").exists, "A later turn keeps the nudged turn's screenshot.")
        attachScreenshot(named: "Claude nudged turn work after a later turn")
    }
    // case-contract: test_codex_nudged_turn_work_stays_in_conversation | A Codex turn that reports no outcome receives Playhouse's private status nudge, and the nudged turn keeps working, with a message the user steers into it kept too: its commentary, its shell command, and its final answer are streamed and appear in fresh history after the earlier answer, with the shell command as a timeline tool row, and the completed outcome it reports moves the task to Review. Fresh history shows the nudge prompt Playhouse sent exactly once as its own message, with no placeholder replacing it; after a later ordinary turn the earlier nudge stays shown, the later turn's own nudge appears after its message, and no placeholder replaces either. The steered message is recorded inside the nudge turn it joined rather than as a turn of its own, and the transcript shows the turn's work above it and the final answer below it. The work the turn streams after the steer follows it, and while the turn still runs it renders below the steered message.
    func test_codex_nudged_turn_work_stays_in_conversation() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-nudged-work-success")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        codexFixtureExecutable = executable.path
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let codexEnvironment = ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": executable.path]
        let steerReady = URL(fileURLWithPath: executable.path + ".nudged-steer-ready")
        try "Hold the nudged turn for a steer.\n".write(to: URL(fileURLWithPath: executable.path + ".nudged-steer-pause"), atomically: true, encoding: .utf8)
        try "Hold the nudged turn's final answer.\n".write(to: URL(fileURLWithPath: executable.path + ".nudged-final-pause"), atomically: true, encoding: .utf8)
        let commentary = "Codex is finishing the remaining check after the nudge."
        let finalReport = "Codex finished the remaining check after the nudge. Everything is done."
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex nudged work", roots: [fixture.primary.path])
        let nudgedTaskID = try taskID(named: "Codex nudged work")
        openTask(named: "Codex nudged work")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Start the work.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: steerReady.path) }, timeout: 40),
                      "The private nudge turn should start and wait for a steer.")
        let steerResult = try runCLI(["conversation", "steer", nudgedTaskID, "--message", "Also double check the docs."], extraEnvironment: codexEnvironment)
        XCTAssertEqual((steerResult["result"] as? [String: Any])?["accepted"] as? Bool, true, "A user can steer the running nudge turn.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable.path + ".nudged-final-ready") }, timeout: 40),
                      "The steered nudge turn keeps working before its final answer.")
        // The steer came from outside this window, which follows the running turn's stream: what the
        // turn streams after the steer renders below it while the turn still runs.
        XCTAssertTrue(element("pause-response-button").exists, "The steered nudge turn is still running.")
        assertWorkStaysAboveSteer("Also double check the docs.", state: "while the steered nudge turn runs")
        let liveCommentary = transcriptMessage(commentary)
        XCTAssertTrue(liveCommentary.waitToExist(timeout: 10), "The work streamed after the steer shows while the turn runs.")
        XCTAssertLessThanOrEqual(transcriptMessage("Also double check the docs.").frame.maxY, liveCommentary.frame.minY,
                                 "The work streamed after the steer renders below it while the turn runs.")
        // The earlier turn's answer already settled as a final answer; the work item streamed after
        // the steer must not take its place above the steer, nor repeat it.
        let heldHistory = try XCTUnwrap(try runCLI(["conversation", "history", nudgedTaskID], extraEnvironment: codexEnvironment)["result"] as? [String: Any])
        let earlierAnswer = try XCTUnwrap((heldHistory["messages"] as? [[String: Any]])?
            .first { $0["role"] as? String == "assistant" }?["text"] as? String)
        XCTAssertTrue(transcriptMessage(earlierAnswer).waitToExist(timeout: 10), "The earlier answer stays shown while the steered turn runs.")
        XCTAssertLessThanOrEqual(transcriptMessage(earlierAnswer).frame.maxY, transcriptMessage("Also double check the docs.").frame.minY,
                                 "The earlier answer stays above the steer while the turn runs.")
        XCTAssertEqual(assistantBubbles(labeled: earlierAnswer).count, 1,
                       "The earlier answer is shown once while the steered turn runs.")
        attachScreenshot(named: "Codex nudged turn: work after the steer streams below it")
        try "Finish the nudged turn.\n".write(to: URL(fileURLWithPath: executable.path + ".nudged-final-release"), atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: nudgedTaskID)?["status"] as? String) == "Review" }, timeout: 40),
                      "The completed outcome reported inside the nudged turn should move the task to Review.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(finalReport) }, timeout: 15),
                      "The nudged turn's final answer should appear in the visible transcript.")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", nudgedTaskID], extraEnvironment: codexEnvironment)["result"] as? [String: Any])
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        let assistant = messages.filter { $0["role"] as? String == "assistant" }.map { [($0["phase"] as? String) ?? "", ($0["text"] as? String) ?? ""] }
        XCTAssertTrue(messages.contains { $0["role"] as? String == "user" && $0["text"] as? String == "Also double check the docs." },
                      "The steered message that joined the nudge turn should stay in the conversation.")
        let steer = messages.first { $0["role"] as? String == "user" && $0["text"] as? String == "Also double check the docs." }
        let nudge = messages.first { $0["role"] as? String == "user" && (($0["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:") }
        XCTAssertNotNil(steer?["turnID"] as? String)
        XCTAssertEqual(steer?["turnID"] as? String, nudge?["turnID"] as? String,
                       "The steered message is recorded inside the nudge turn it joined, not as a turn of its own.")
        let steerBubble = transcriptMessage("Also double check the docs.")
        let finalBubble = transcriptMessage(finalReport)
        XCTAssertTrue(steerBubble.waitToExist(timeout: 10) && element("codex-activity-disclosure").waitToExist(timeout: 10))
        XCTAssertLessThanOrEqual(element("codex-activity-disclosure").frame.maxY, steerBubble.frame.minY,
                                 "The turn's work stays above the message steered into it.")
        XCTAssertLessThanOrEqual(steerBubble.frame.maxY, finalBubble.frame.minY, "The answer that followed the steer renders below it.")
        XCTAssertGreaterThan(assistant.count, 2, "The earlier answer should stay ahead of the nudged work.")
        XCTAssertEqual(Array(assistant[1...2]), [["commentary", commentary], ["final_answer", finalReport]],
                       "The nudged work should follow the earlier answer in order.")
        XCTAssertEqual(messages.last?["text"] as? String, finalReport, "The nudged turn's final answer is the latest message.")
        let timeline = (history["timelineActivities"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == "item_nudged_check_1" }
        XCTAssertEqual(timeline.first?["input"] as? String, "echo NUDGED CHECK PASSED", "The nudged shell command should be a timeline row.")
        XCTAssertEqual(messages.filter { $0["role"] as? String == "user" && (($0["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:") }.count, 1,
                       "Fresh history shows the nudge Playhouse sent exactly once.")
        XCTAssertTrue(transcriptContains("ended without reporting a task outcome"), "The nudge Playhouse sent is shown in the transcript.")
        try assertAutomaticMessageBubble(taskID: nudgedTaskID, containing: "ended without reporting a task outcome")
        XCTAssertFalse(transcriptContains("Playhouse private outcome"), "No placeholder replaces the nudge.")
        attachScreenshot(named: "Codex nudged turn work follows the earlier answer")
        XCTAssertTrue(expandLatestWorkedFor(), "The nudged turn's work should collapse into an expandable Worked for summary.")
        XCTAssertTrue(element("codex-activity-row-item_nudged_check_1").waitToExist(timeout: 10),
                      "The nudged turn's shell command should be listed in its Worked for details.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(commentary) }, timeout: 10), "Worked for should list the nudged turn's commentary.")
        attachScreenshot(named: "Codex nudged turn Worked for shows its command")

        element("back-to-board-button").click()
        assertTaskVisible("Codex nudged work", inColumn: "Review")
        attachScreenshot(named: "Codex nudged task in Review")
        openTask(named: "Codex nudged work")
        XCTAssertTrue(waitUntil({ self.transcriptContains(finalReport) }, timeout: 15), "Reopening keeps the nudged turn's final answer.")
        XCTAssertTrue(expandLatestWorkedFor(), "Reopening keeps the nudged turn's Worked for summary.")
        XCTAssertTrue(waitUntil({ self.transcriptContains(commentary) }, timeout: 10), "Reopening keeps the nudged turn's commentary.")

        try sendLaterTurnAndAssertNudgedCallInline(taskID: nudgedTaskID, callID: "item_nudged_check_1", visibleTexts: [finalReport, commentary])
        XCTAssertEqual(try taskRecord(id: nudgedTaskID)?["status"] as? String, "Review",
                       "The later turn's own nudge keeps working and reports completed instead of blocking the task.")
        let laterMessages = try XCTUnwrap((try runCLI(["conversation", "history", nudgedTaskID], extraEnvironment: codexEnvironment)["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        let laterStart = try XCTUnwrap(laterMessages.lastIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Thanks, that's all." })
        XCTAssertTrue(laterMessages[(laterStart + 1)...].contains { $0["role"] as? String == "user" && (($0["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:") },
                      "The later turn's own nudge is shown after its message.")
        attachScreenshot(named: "Codex nudged turn work after a later turn")
    }
    // case-contract: test_claude_steers_turn_parked_on_background_work | A Claude turn whose result is already out while a background shell keeps it open is still steerable: a queued follow-up's Steer reaches the running turn instead of silently staying queued, leaves the queue, appears in the conversation, and the turn waits for Claude's answer to it before the woken parent turn ends the send. The steered follow-up is recorded inside the turn it steered rather than as a turn of its own, so the transcript keeps it in order: while the turn runs and after it ends, the turn's work stays above its bubble, as does the answer given before it while it is shown, and what the turn said after it renders below it. Once Claude's answer to the steer has its own result while the shell still holds the turn open, that answer is already recorded in history exactly once, below the steered follow-up with the answer given before the steer above it, and stays shown rather than living only in the stream; after the turn ends both earlier answers are kept once as commentary and only the woken parent turn's answer is final.
    func test_claude_steers_turn_parked_on_background_work() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-parked-steer")
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
        let parkedReady = URL(fileURLWithPath: executable.path + ".parked-shell-ready")
        let steeredAnswerPause = URL(fileURLWithPath: executable.path + ".steered-answer-pause")
        let steeredAnswerReady = URL(fileURLWithPath: executable.path + ".steered-answer-ready")
        let steeredAnswerRelease = URL(fileURLWithPath: executable.path + ".steered-answer-release")
        try Data().write(to: steeredAnswerPause, options: .atomic)
        defer {
            try? Data("Release the steered-answer fixture pause.\n".utf8).write(to: steeredAnswerRelease, options: .atomic)
            try? FileManager.default.removeItem(at: steeredAnswerPause)
            try? FileManager.default.removeItem(at: steeredAnswerReady)
            try? FileManager.default.removeItem(at: steeredAnswerRelease)
        }
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude parked steer", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude parked steer")
        element("message-composer").click()
        element("message-composer").typeText("Launch a parked background shell for this turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: parkedReady.path) }, timeout: 15),
                      "The fixture should park the turn after its result while the shell runs.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("PARKED STARTED") }, timeout: 10))
        XCTAssertTrue(waitUntil({ self.element("pause-response-button").exists }, timeout: 10),
                      "The parked turn must still read as the active turn after its provider result settles.")

        let followUp = "Check the other blocked tasks too."
        let composer = element("message-composer")
        composer.click()
        composer.typeText(followUp)
        composer.typeKey(.return, modifierFlags: [])
        let queued = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let queuedID = try XCTUnwrap(queued?.first(where: { $0["text"] as? String == followUp })?["id"] as? String)
        let steerButton = element("steer-queued-message-\(queuedID)")
        XCTAssertTrue(steerButton.waitToExist(timeout: 10), "The queued follow-up should offer its row Steer action.")
        attachScreenshot(named: "Parked turn with the queued follow-up ready to steer")

        steerButton.click()
        XCTAssertTrue(waitUntil({ self.transcriptContains(followUp) }, timeout: 15),
                      "Steering a turn parked on background work must deliver the follow-up into that turn.")
        XCTAssertTrue(waitUntil({ (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])??.isEmpty == true }, timeout: 10),
                      "An accepted steer must leave the queue.")
        XCTAssertFalse(element("queued-message-text-\(queuedID)").exists, "The steered row should no longer be queued.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: steeredAnswerReady.path) }, timeout: 10),
                      "Claude should answer the steered follow-up while the shell still runs.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("STEERED: \(followUp)") }, timeout: 15),
                      "Claude's answer to the steered follow-up stays shown after its result, while the turn is parked.")
        XCTAssertTrue(element("pause-response-button").exists, "The parked turn remains active until its woken parent answer arrives.")
        // Nothing settles the turn yet, so the answer must already be recorded, in order, not only streamed.
        let parked = try XCTUnwrap(try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let parkedTexts = (parked["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        for text in ["PARKED STARTED", followUp, "STEERED: \(followUp)"] {
            XCTAssertEqual(parkedTexts.filter { $0 == text }.count, 1, "\(text) is recorded once while the turn is parked.")
        }
        if let started = parkedTexts.firstIndex(of: "PARKED STARTED"), let steered = parkedTexts.firstIndex(of: followUp),
           let answer = parkedTexts.firstIndex(of: "STEERED: \(followUp)") {
            XCTAssertTrue(started < steered, "The answer given before the steer stays above it in history.")
            XCTAssertTrue(steered < answer, "Claude's answer to the steer follows it in history.")
        }
        assertSteerFollowsEarlierWork(followUp, earlierAnswer: "PARKED STARTED", laterAnswer: "STEERED: \(followUp)", state: "while the turn runs")
        attachScreenshot(named: "Steered follow-up answered inside the parked turn")

        try Data("Release after the same-turn answer is visible.\n".utf8).write(to: steeredAnswerRelease, options: .atomic)
        XCTAssertTrue(waitUntil({ self.transcriptContains("PARKED HANDLED") }, timeout: 20),
                      "The woken parent turn's answer still ends the turn.")
        let history = try XCTUnwrap(try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let messages = history["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(messages.contains { $0["role"] as? String == "user" && $0["text"] as? String == followUp },
                      "The steered follow-up belongs in the conversation it steered.")
        XCTAssertEqual(messages.filter { $0["role"] as? String == "assistant" }.last?["text"] as? String, "PARKED HANDLED")
        let assistant = messages.filter { $0["role"] as? String == "assistant" }
            .map { "\($0["phase"] as? String ?? "") \($0["text"] as? String ?? "")" }
        XCTAssertEqual(Array(assistant.suffix(3)),
                       ["commentary PARKED STARTED", "commentary STEERED: \(followUp)", "final_answer PARKED HANDLED"],
                       "Answers recorded while the turn was parked are kept once, and only the turn's last answer is final.")
        let question = messages.first { $0["role"] as? String == "user" && $0["text"] as? String == "Launch a parked background shell for this turn." }
        let steer = messages.first { $0["role"] as? String == "user" && $0["text"] as? String == followUp }
        XCTAssertNotNil(steer?["turnID"] as? String)
        XCTAssertEqual(steer?["turnID"] as? String, question?["turnID"] as? String,
                       "The steered follow-up is recorded inside the turn it steered, not as a turn of its own.")
        // The finished turn folds its progress into its work, which stays above the steer. The
        // outcome nudge that follows the turn scrolls the transcript; the order is read once
        // that private turn has settled the task, so both frames come from the same layout.
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 15),
                      "The outcome nudge after the parked turn settles the task on the user.")
        XCTAssertTrue(waitForStableFrame(transcriptMessage(followUp)), "The transcript stops moving once the nudge turn is shown.")
        assertSteerFollowsEarlierWork(followUp, earlierAnswer: nil, laterAnswer: "PARKED HANDLED", state: "after the turn ends")
        XCTAssertEqual(assistantBubbles(labeled: "PARKED HANDLED").count, 1, "The woken parent turn's answer is shown once.")
        attachScreenshot(named: "Parked turn finished after the steered follow-up")
    }

    // case-contract: test_claude_steer_keeps_answer_written_before_it_above | A Claude turn that answers, then publishes a Playhouse progress report, which leaves that answer open, takes a steer at the report's tool boundary: the answer written before the steer is recorded once, above the steered message, as soon as the steer reaches Claude, rather than after Claude's reply to it, and the reply streams below the steer and stays shown while it is still being written instead of being cleared when the earlier answer is closed. After the turn ends the earlier answer stays above the steer as commentary and the reply is the final answer below it, each once. Only Claude Code keeps an answer open across a progress report, so Claude is the representative provider for this Playhouse-owned transcript order.
    func test_claude_steer_keeps_answer_written_before_it_above() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-reported-steer")
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
        let steerReady = URL(fileURLWithPath: executable.path + ".reported-steer-ready")
        let replyPause = URL(fileURLWithPath: executable.path + ".steer-reply-pause")
        let replyReady = URL(fileURLWithPath: executable.path + ".steer-reply-ready")
        let replyRelease = URL(fileURLWithPath: executable.path + ".steer-reply-release")
        try Data().write(to: replyPause, options: .atomic)
        defer {
            try? Data("Release the steer-reply fixture pause.\n".utf8).write(to: replyRelease, options: .atomic)
            try? FileManager.default.removeItem(at: replyPause)
            try? FileManager.default.removeItem(at: replyReady)
            try? FileManager.default.removeItem(at: replyRelease)
        }
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude reported steer", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"
        ]) ["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Claude reported steer")
        element("message-composer").click()
        element("message-composer").typeText("Please answer, report progress, await steering.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: steerReady.path) }, timeout: 15),
                      "The fixture should answer, report progress and wait for a steer.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("REPORTED ANSWER") }, timeout: 10))

        let steer = "Also cover the docs."
        let reply = "STEER REPLY: \(steer)"
        let composer = element("message-composer")
        composer.click()
        composer.typeText(steer)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: replyReady.path) }, timeout: 15),
                      "Claude should reply to the steer.")
        // The reply has streamed and its message arrived, but not its result: closing the answer
        // written before the steer must not clear it.
        XCTAssertTrue(waitUntil({ self.transcriptContains(reply) }, timeout: 15),
                      "The reply to the steer stays shown while it is still being written.")
        XCTAssertTrue(element("pause-response-button").exists, "The turn is still running.")
        assertSteerFollowsEarlierWork(steer, earlierAnswer: "REPORTED ANSWER", laterAnswer: reply, state: "while the reply is written")
        let running = try XCTUnwrap(try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let runningTexts = (running["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertEqual(runningTexts.filter { $0 == "REPORTED ANSWER" }.count, 1, "The answer before the steer is recorded once.")
        XCTAssertEqual(runningTexts.filter { $0 == steer }.count, 1, "The steer is recorded once.")
        if let answer = runningTexts.firstIndex(of: "REPORTED ANSWER"), let steered = runningTexts.firstIndex(of: steer) {
            XCTAssertTrue(answer < steered, "The answer written before the steer is recorded above it.")
        }
        attachScreenshot(named: "Reply to the steer shown below it while being written")

        try Data("Release after the reply is visible.\n".utf8).write(to: replyRelease, options: .atomic)
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The turn ends on the reply.")
        // The finished turn folds its commentary into its work, which stays above the steer.
        assertSteerFollowsEarlierWork(steer, earlierAnswer: nil, laterAnswer: reply, state: "after the turn ends")
        XCTAssertEqual(assistantBubbles(labeled: reply).count, 1, "The reply is shown once after the turn ends.")
        let history = try XCTUnwrap(try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )["result"] as? [String: Any])
        let turn = (history["messages"] as? [[String: Any]] ?? [])
            .filter { ["REPORTED ANSWER", steer, reply].contains($0["text"] as? String) }
            .map { "\($0["role"] as? String ?? "") \($0["phase"] as? String ?? "-") \($0["text"] as? String ?? "")" }
        XCTAssertEqual(turn, ["assistant commentary REPORTED ANSWER", "user - \(steer)", "assistant final_answer \(reply)"],
                       "After the turn the answer before the steer stays above it and the reply is the final answer below it, each once.")
        attachScreenshot(named: "Turn finished with the reply below the steer")
    }

    /// A steered message reads in order: the turn's work and the answer before it sit above its
    /// bubble, and what the turn did after it sits below.
    private func assertSteerFollowsEarlierWork(_ steer: String, earlierAnswer: String?, laterAnswer: String, state: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let bubble = transcriptMessage(steer)
        let later = transcriptMessage(laterAnswer)
        let work = element("codex-activity-disclosure")
        XCTAssertTrue(bubble.waitToExist(timeout: 10) && later.waitToExist(timeout: 10) && work.waitToExist(timeout: 10),
                      "The steer, the answer after it, and the turn's work are all shown \(state).", file: file, line: line)
        XCTAssertLessThanOrEqual(work.frame.maxY, bubble.frame.minY,
                                 "The work the turn did before the steer stays above the steered message \(state).", file: file, line: line)
        if let earlierAnswer {
            let earlier = transcriptMessage(earlierAnswer)
            XCTAssertTrue(earlier.waitToExist(timeout: 10), "The answer given before the steer is shown \(state).", file: file, line: line)
            XCTAssertLessThanOrEqual(earlier.frame.maxY, bubble.frame.minY,
                                     "The answer given before the steer stays above it \(state).", file: file, line: line)
            // Claude closes that answer as an item at its result or when the steer reaches it,
            // which can follow the steer's bubble; the item settles where the answer streamed
            // instead of repeating below the steer.
            XCTAssertEqual(assistantBubbles(labeled: earlierAnswer).count, 1,
                           "The answer given before the steer is shown once \(state).", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(bubble.frame.maxY, later.frame.minY,
                                 "What the turn said after the steer renders below it \(state).", file: file, line: line)
    }

    /// Assistant message bubbles showing `text`; their markdown paragraphs carry the same label.
    private func assistantBubbles(labeled text: String) -> XCUIElementQuery {
        app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", text))
    }
}

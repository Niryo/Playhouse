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
    // case-contract: test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request | When the bridge daemon dies in the middle of a turn, that turn's send fails with a connection error instead of hanging, but the provider keeps running in its own session. The next request starts a fresh daemon on demand, which reattaches the running turn so the task stays In Progress with no restart notice, stops that reattached turn, and can then run and stop a new turn.
    func test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold-interrupt").path
        codexFixtureExecutable = executable
        let ready = URL(fileURLWithPath: executable + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable + ".interrupt-received")
        let release = URL(fileURLWithPath: executable + ".interrupt-release")
        for marker in [ready, received, release] { try? FileManager.default.removeItem(at: marker) }
        // Its own daemon, so killing it leaves the UI runner's shared one alone.
        let daemonEnvironment = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).death-\(UUID().uuidString.prefix(8))"]
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Daemon death", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemonEnvironment)
        openTask(named: "Daemon death")
        sendFromComposer("Hold until the daemon dies.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The turn should be running before the daemon dies.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        let firstPID = try XCTUnwrap(try daemonProcessID(environment: daemonEnvironment))
        let server = try XCTUnwrap(agentManifest(kind: "codex", service: daemonEnvironment)?.manifest["process"] as? [String: Any])

        kill(pid_t(firstPID), SIGKILL)
        // The window starts the fresh daemon itself while it reconnects, and follows the turn.
        var secondPID = firstPID
        XCTAssertTrue(waitUntil({
            secondPID = (try? self.daemonProcessID(environment: daemonEnvironment)) ?? firstPID
            return secondPID != firstPID
        }, timeout: 20), "The window should start a fresh daemon while it reconnects.")
        XCTAssertEqual(kill(pid_t(secondPID), 0), 0)
        XCTAssertTrue(agentIsAlive(server), "The provider outlives the daemon.")
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.exists && stop.isEnabled }, timeout: 20), "The window keeps showing the reattached turn as running.")
        XCTAssertFalse(element("codex-chat-error").exists, "The turn survives, so the window shows no error.")
        let recovered = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(recovered["status"] as? String, "In Progress")
        XCTAssertFalse((recovered["statusMessage"] as? String ?? "").contains("closed while"))
        attachScreenshot(named: "daemon-death-turn-survives")

        // Stop the reattached turn, then run and stop a new one on the fresh daemon.
        stop.click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10), "Stop reaches the reattached turn.")
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 15))
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response"))
        for marker in [ready, received, release] { try? FileManager.default.removeItem(at: marker) }
        sendFromComposer("Hold again on the fresh daemon.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20), "The fresh daemon should run a new turn.")
        XCTAssertTrue(waitUntil({ stop.exists && stop.isEnabled }, timeout: 20), "The window should follow the fresh daemon and offer Stop.")
        stop.click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10))
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 15))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
    }
    // case-contract: test_codex_background_wait_survives_daemon_restart | A daemon killed while a task waits for a command its Codex turn left running does not strand the task: the next daemon finds the persisted wait, reconnects to the same app-server, keeps the task In Progress with no new prompt, and resumes reconciling the provider's background terminals. A command that ends after the restart has its real exit status and output delivered once, and the agent's rerun is waited for again. A command that ended while no daemon was connected is reported to the agent as having no result Playhouse saw, never as successful, and the agent's blocked outcome settles the task in Blocked with its reason. The user's message appears once in history across both restarts.
    func test_codex_background_wait_survives_daemon_restart() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-unique-turns-background-retry-daemon").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable), "The background fixture should be installed.")
        codexFixtureExecutable = executable
        clearReattachMarkers(executable)
        func backgroundState() -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable + ".background-state")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return state
        }
        func running() -> Int { (backgroundState()["running"] as? [String: Any])?.count ?? 0 }
        func count(_ key: String) -> Int { backgroundState()[key] as? Int ?? 0 }
        func releaseCommand(_ result: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: executable + ".background-release"), options: .atomic)
        }
        func fixtureTurns() throws -> [String] {
            let history = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable + ".history"))) as? [String: Any]
            )
            return try XCTUnwrap(history["turns"] as? [[String: Any]]).map { $0["userMessage"] as? String ?? "" }
        }
        let environment = restartServiceEnvironment(["PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS": "0.2"])
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Waits across a restart", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Waits across a restart")
        sendFromComposer("Run the required UI test.")
        XCTAssertTrue(waitUntil({ running() == 1 && count("listCalls") >= 2 }, timeout: 30), "The command should be waited for before the daemon dies.")
        let server = try XCTUnwrap(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? [String: Any])

        try killDaemon(environment: environment)
        let callsBeforeRestart = count("listCalls")
        // The window reconnects; the fresh daemon picks the wait up.
        XCTAssertTrue(waitUntil({ running() == 1 && count("listCalls") >= callsBeforeRestart + 3 }, timeout: 40),
                      "The fresh daemon should resume reconciling the running command.")
        XCTAssertEqual(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? NSDictionary, server as NSDictionary,
                       "The fresh daemon reconnects to the same app-server.")
        XCTAssertTrue(waitForStatus(taskID, "In Progress", environment: environment), "A wait cut off by a restart keeps the task In Progress.")
        XCTAssertEqual(try fixtureTurns().count, 1, "Resuming the wait sends the model no prompt.")
        XCTAssertFalse(element("codex-chat-error").exists, "A resumed wait is not a failed turn.")
        assertTaskVisible("Waits across a restart", inColumn: "In Progress")
        attachScreenshot(named: "Task stays In Progress after the daemon restarts mid-wait")

        try releaseCommand(["exitCode": 1, "output": "XCTAssertEqual failed: fixture regression\n"])
        XCTAssertTrue(waitUntil({ count("started") == 2 && running() == 1 }, timeout: 30),
                      "The agent should rerun the command after reading the failure delivered after the restart.")
        var turns = try fixtureTurns()
        XCTAssertEqual(turns.count, 2, "The result is delivered in exactly one private turn.")
        XCTAssertTrue(turns[1].contains("failed, exit code 1"))
        XCTAssertTrue(turns[1].contains("XCTAssertEqual failed: fixture regression"))
        let rerunCalls = count("listCalls")
        XCTAssertTrue(waitUntil({ count("listCalls") >= rerunCalls + 3 }, timeout: 30), "The rerun should be waited for before the second restart.")
        XCTAssertTrue(waitForStatus(taskID, "In Progress", environment: environment), "A rerun that is running keeps the task In Progress.")
        openTask(named: "Waits across a restart")
        XCTAssertTrue(waitUntil({ self.transcriptContains("failed, exit code 1") }, timeout: 15), "The result delivered after the restart must appear in the visible transcript.")
        attachScreenshot(named: "Failure delivered after the restart and rerun in progress")

        // The rerun ends with no daemon connected: its completion event reaches nobody.
        try killDaemon(environment: environment)
        try releaseCommand(["vanish": true])
        XCTAssertTrue(waitForStatus(taskID, "Blocked", environment: environment, timeout: 60), "The agent's outcome for the lost result should settle the task.")
        let settled = try XCTUnwrap(try runCLI(["task", "get", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertTrue((settled["statusMessage"] as? String)?.contains("without a result") == true)
        turns = try fixtureTurns()
        XCTAssertEqual(turns.count, 3, "The lost result is reported in exactly one more private turn.")
        XCTAssertTrue(turns[2].contains("Playhouse did not see its result"))
        XCTAssertFalse(turns[2].contains("exit code 0"), "A command that ended unseen is not assumed to have passed.")
        XCTAssertFalse(turns[2].contains("XCTAssertEqual failed"), "A delivered result is not delivered again.")
        XCTAssertEqual((backgroundState()["terminated"] as? [String]) ?? [], [])
        XCTAssertEqual(try historyTexts(taskID: taskID, environment: environment).filter { $0 == "Run the required UI test." }.count, 1,
                       "The user's message appears once across both restarts.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Playhouse did not see its result") }, timeout: 15), "The lost result's report must appear in the visible transcript.")
        attachScreenshot(named: "Lost result reported after the second restart")
        assertTaskVisible("Waits across a restart", inColumn: "Blocked")
        let cardMessage = element("task-status-message-\(taskID)")
        XCTAssertTrue(cardMessage.waitToExist(timeout: 10), "The Blocked card should show the agent's reason.")
        XCTAssertTrue(accessibleLabelOrValue(of: cardMessage).contains("without a result"))
        attachScreenshot(named: "Blocked card after the result was lost in a restart")
    }
    // case-contract: test_codex_turn_reattaches_after_daemon_restart | A Codex turn keeps running in its shared socket app-server when the daemon is killed: the next daemon reconnects to the same server (no second server, one connection per daemon), keeps the task In Progress with no restart notice, shows the output written before the restart exactly once, saves the question the server re-sends on resume and answers the re-sent approval exactly once, accepts a steered follow-up, streams the rest of the turn to a watcher, and settles it through the normal outcome path. A turn that finished while no daemon was connected settles from the server's state, which the next daemon reads once to record the output it missed, exactly once and without an outcome command its answer echoed. A question the shared server raises on a thread no conversation owns gets no reply from the connected client, which leaves it for its owner instead of rejecting it.
    func test_codex_turn_reattaches_after_daemon_restart() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-reattach").path
        codexFixtureExecutable = executable
        clearReattachMarkers(executable)
        let environment = restartServiceEnvironment(["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS": "3"])
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Codex reattach", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Codex reattach")
        sendFromComposer("Keep working across a restart.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20), "The turn should be running.")
        XCTAssertTrue(transcriptMessage("Before restart.").waitToExist(timeout: 15))
        let server = try XCTUnwrap(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? [String: Any])
        attachScreenshot(named: "codex-reattach-1-running-before-restart")

        try killDaemon(environment: environment)
        XCTAssertTrue(agentIsAlive(server), "The app-server outlives the daemon that started it.")
        touch(executable + ".reattach-raise")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-raised") }, timeout: 10))
        // The window reconnects; the fresh daemon reattaches the turn and re-receives the question.
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 30), "The question raised during the restart appears.")
        XCTAssertFalse(element("codex-chat-error").exists, "A reattached turn is not a failed turn.")
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
        XCTAssertFalse((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("restarting"))
        XCTAssertEqual(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? NSDictionary, server as NSDictionary,
                       "The fresh daemon reconnects to the same app-server.")
        XCTAssertTrue(transcriptMessage("Before restart.").exists)
        attachScreenshot(named: "codex-reattach-2-question-after-restart")
        selectQuestionOption("blue")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(transcriptMessage("Answer received: blue.").waitToExist(timeout: 15))
        steerFromComposer("Also check the README.")
        XCTAssertTrue(waitUntil({ !self.jsonLines(executable + ".reattach-steers").isEmpty }, timeout: 15), "The follow-up steers the reattached turn.")
        // The steer also makes the server raise a question on a thread no conversation owns; the
        // connected client leaves it for its owner instead of rejecting it.
        XCTAssertTrue(waitUntil({
            ((try? self.diagnosticEvents()) ?? []).contains {
                $0["event"] as? String == "codex.user_input.unowned_ignored" && $0["threadID"] as? String == "thread-owned-by-no-conversation"
            }
        }, timeout: 15), "The connected client should leave an unowned question unanswered.")
        XCTAssertTrue(jsonLines(executable + ".reattach-replies").compactMap { $0 as? [String: Any] }.filter { $0["id"] as? String == "question-foreign" }.isEmpty,
                      "No client should reply to a question it does not own.")
        touch(executable + ".reattach-release")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The window follows the reattached turn to its end.")
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
        attachScreenshot(named: "codex-reattach-3-finished")
        // Each agent message is its own history entry; count within the joined text.
        let texts = try historyTexts(taskID: taskID, environment: environment)
        let joinedHistory = texts.joined(separator: "\n")
        for text in ["Before restart.", "Answer received: blue.", "After restart."] {
            XCTAssertEqual(joinedHistory.components(separatedBy: text).count - 1, 1, "\(text) appears exactly once: \(texts)")
        }
        let replies = jsonLines(executable + ".reattach-replies").compactMap { $0 as? [String: Any] }
        XCTAssertEqual(replies.filter { ($0["id"] as? String ?? "").hasPrefix("approval-") }.count, 1, "The re-sent approval is answered once.")
        XCTAssertEqual(replies.filter { ($0["id"] as? String ?? "").hasPrefix("question-") }.count, 1, "The question is answered once.")
        let connections = jsonLines(executable + ".socket-log").compactMap { $0 as? [String: Any] }.filter { $0["event"] as? String == "connected" }
        XCTAssertGreaterThanOrEqual(connections.count, 2, "Each daemon reconnects to the same server; the CLI case asserts exactly one per daemon.")

        // A turn that finishes while no daemon is connected settles once the window reconnects.
        try? FileManager.default.removeItem(atPath: executable + ".reattach-ready")
        sendFromComposer("Finish while Playhouse is down.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
        try killDaemon(environment: environment)
        // Its answer also echoes the outcome command, which the backfill records without.
        touch(executable + ".reattach-leak-outcome")
        touch(executable + ".reattach-release")
        XCTAssertTrue(waitUntil({
            (((try? self.historyTexts(taskID: taskID, environment: environment)) ?? []).joined(separator: "\n")).components(separatedBy: "After restart.").count - 1 == 2
        }, timeout: 40))
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment, timeout: 40))
        // The output it missed is recorded exactly once, also once the turn has settled.
        let settledHistory = try historyTexts(taskID: taskID, environment: environment).joined(separator: "\n")
        XCTAssertEqual(settledHistory.components(separatedBy: "After restart.").count - 1, 2,
                       "The backfilled reply is recorded exactly once.")
        XCTAssertEqual(try historyTexts(taskID: taskID, environment: environment).filter { $0.contains("After restart.") },
                       ["After restart.", "After restart."], "The backfilled answer is recorded without the outcome command it echoed.")
        XCTAssertTrue(waitUntil({
            self.app.groups.matching(NSPredicate(format: "label == %@", "After restart.")).count == 2
        }, timeout: 15), "The window shows the backfilled reply once, after the earlier one.")
        attachScreenshot(named: "codex-reattach-4-backfilled-while-down")
        XCTAssertFalse(element("codex-chat-error").exists)
    }
    // case-contract: test_claude_turn_reattaches_after_daemon_restart | A Claude Code turn with file-backed stdio keeps running when the daemon is killed: the next daemon replays the handled log without repeating its writes, keeps the task In Progress, shows the output written before the restart once, restores the still unanswered question and never answers an answered request again, ignores a late reply to the old daemon's request and numbers its own requests past the old ones, delivers a steered follow-up, streams the rest of the turn to a watcher, records the turn's usage once, settles it through its outcome, and removes the finished run.
    func test_claude_turn_reattaches_after_daemon_restart() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-reattach").path
        claudeFixtureExecutable = executable
        clearReattachMarkers(executable)
        let environment = restartServiceEnvironment()
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude reattach", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Claude reattach")
        sendFromComposer("Keep working across a restart.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
        touch(executable + ".reattach-ask")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15), "The question appears before the restart.")
        let run = try XCTUnwrap(agentManifest(kind: "claude", service: environment))
        let agent = try XCTUnwrap(run.manifest["process"] as? [String: Any])
        attachScreenshot(named: "claude-reattach-1-question-before-restart")

        try killDaemon(environment: environment)
        XCTAssertTrue(agentIsAlive(agent), "Claude Code outlives the daemon that started it.")
        touch(executable + ".reattach-late-reply")
        // The window reconnects; the fresh daemon replays the run and restores the question once.
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
        XCTAssertFalse(element("codex-chat-error").exists, "A reattached turn is not a failed turn.")
        let reconnected = try runCLI(["task", "get", taskID], extraEnvironment: environment)["result"] as? [String: Any]
        XCTAssertFalse((reconnected?["statusMessage"] as? String ?? "").contains("restarting"), "No restart notice after reconnecting.")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 15))
        XCTAssertTrue(agentIsAlive(agent))
        attachScreenshot(named: "claude-reattach-2-question-after-restart")
        selectQuestionOption("blue")
        element("submit-ai-answers-button").click()
        steerFromComposer("Also check the README.")
        XCTAssertTrue(waitUntil({ !self.jsonLines(executable + ".reattach-steers").isEmpty }, timeout: 15), "The follow-up reaches the running process.")
        touch(executable + ".reattach-release")
        XCTAssertTrue(transcriptMessage("After restart.").waitToExist(timeout: 20), "The window streams the rest of the reattached turn.")
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
        attachScreenshot(named: "claude-reattach-3-finished")
        let finalStatus = try runCLI(["task", "get", taskID], extraEnvironment: environment)["result"] as? [String: Any]
        XCTAssertFalse((finalStatus?["statusMessage"] as? String ?? "").contains("restarting"), "A reattached turn shows no restart notice.")
        let usage = try XCTUnwrap(try runCLI(["task", "token-usage", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        let claudeTurns = (usage["turns"] as? [[String: Any]] ?? []).filter { $0["provider"] as? String == "claude" }
        XCTAssertEqual(claudeTurns.count, 1, "The reattached turn records its usage once.")
        let texts = try historyTexts(taskID: taskID, environment: environment)
        for text in ["Before restart.", "Answer received: blue.", "After restart."] {
            XCTAssertEqual(texts.filter { $0 == text }.count, 1, "\(text) appears exactly once: \(texts)")
        }
        let replies = jsonLines(executable + ".reattach-replies").compactMap { ($0 as? [String: Any])?["id"] as? String }
        XCTAssertEqual(replies.filter { $0 == "reattach-approval-1" }.count, 1, "An answered request isn't answered again.")
        XCTAssertEqual(replies.filter { $0 == "reattach-question-1" }.count, 1)
        let requestNumbers = jsonLines(executable + ".reattach-stdin").compactMap { $0 as? String }
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["type"] as? String == "control_request" }
            .compactMap { ($0["request_id"] as? String)?.split(separator: "-").last.flatMap { Int($0) } }
        // The window's own sessions (title, suggestions) also log requests 1 and 2; the strict
        // numbering past the old daemon's is asserted by the CLI case and the stop case.
        XCTAssertTrue(requestNumbers.allSatisfy { $0 <= 2 || $0 >= 1001 }, "A reattached run never reuses the old daemon's numbers: \(requestNumbers)")
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(agent) }, timeout: 15), "The finished run stops.")
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: run.path.deletingLastPathComponent().path) }, timeout: 10))
    }
    // case-contract: test_standalone_chat_turn_filed_after_daemon_restart | A standalone chat turn that is still running when its daemon dies is followed by the next daemon, and when it ends with close-turn --continues false that daemon files the turn's question and answers on the new titled page the close-turn opened, exactly once, leaving the earlier page as it was and no page decision pending. The page's first session is seeded with that turn, so the next question reaches the provider with the turn's question and answer. Filing reads Playhouse's own close-turn record and turn transcript, shared by Claude and Codex once a reattached turn ends, so one representative provider (Claude) covers this case.
    func test_standalone_chat_turn_filed_after_daemon_restart() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat()
        _ = sendFiledRestartChatTurn(executable, "Name a moon of Mars.", environment: environment)
        let earlierID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)
        let earlierTexts = ["Name a moon of Mars.", "Before restart.", "After restart."]
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), earlierTexts, "The daemon that sent the first turn files it.")

        let question = "Could the Android build be split into parallel steps?"
        startRestartChatTurn(executable, question)
        try killDaemon(environment: environment)
        attachScreenshot(named: "standalone-chat-restart-1-turn-in-flight")
        // The window reconnects to the next daemon, which follows the turn: its agent opens a
        // new page with close-turn and finishes the answer.
        closeHeldChatTurn(executable, newTitle: "Parallel Android build")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Parallel Android build") }, timeout: 30),
                      "The reattached turn shows under the page its close-turn opened.")
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows("After restart.", belowPage: "Parallel Android build") }, timeout: 20),
                      "The window shows the reattached turn's answer under its new page.")
        var pageID = ""
        var pageTexts: [String] = []
        XCTAssertTrue(waitUntil({
            guard let status = self.restartChatStatus(environment), status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any], page["title"] as? String == "Parallel Android build",
                  let id = page["id"] as? String else { return false }
            pageID = id
            pageTexts = self.restartChatPageTexts(id, environment: environment)
            return pageTexts == [question, "Before restart.", "After restart."]
        }, timeout: 20), "The reattached turn is filed once on the page its close-turn opened: \(pageTexts)")
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), earlierTexts, "The earlier page keeps only its own turn.")
        let filed = try diagnosticEvents().filter { $0["event"] as? String == "chat.page.reattached_turn.filed" && $0["taskID"] as? String == chatID }
        XCTAssertEqual(filed.map { [$0["pageID"] as? String ?? "", $0["signal"] as? String ?? ""] }, [[pageID, "close-turn"]],
                       "The reattached filing is recorded in diagnostics.")
        attachScreenshot(named: "standalone-chat-restart-2-turn-filed-on-new-page")

        // The new page's first session is seeded with the turn that opened it.
        let seeded = sendFiledRestartChatTurn(executable, "Which step would be slowest?", environment: environment)
        XCTAssertTrue(seeded.contains(question), "The new page's session carries the reattached turn's question.")
        XCTAssertTrue(seeded.contains("After restart."), "The new page's session carries the reattached turn's answer.")
        XCTAssertFalse(seeded.contains("Name a moon of Mars."), "An earlier page never reaches the new page's session.")
        XCTAssertEqual(Array(restartChatPageTexts(pageID, environment: environment).prefix(3)), [question, "Before restart.", "After restart."],
                       "A later turn never files the reattached turn again.")
        XCTAssertTrue(transcriptMessage("Which step would be slowest?").waitToExist(timeout: 10))
        attachScreenshot(named: "standalone-chat-restart-3-next-turn-seeded")
    }
    // case-contract: test_standalone_chat_orphaned_turn_recovered_on_startup | A standalone chat turn that ran close-turn --continues false and then lost both its daemon and its agent before it was filed is filed, question included, by the next daemon on the page that close-turn opened, found from Playhouse's durable close-turn record. An answered turn that an earlier build left unfiled after its close-turn opened a new page, with no close-turn record, is filed by the next daemon as it starts onto the page opened while that turn ran. Both recoveries are recorded in diagnostics, a further daemon restart files nothing again, and the next question's fresh page session is seeded with the recovered turn. Recovery reads only Playhouse's own transcript, close-turn record and page store, so provider selection cannot change it; one representative provider (Claude) covers this case.
    func test_standalone_chat_orphaned_turn_recovered_on_startup() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat()
        _ = sendFiledRestartChatTurn(executable, "Name a moon of Mars.", environment: environment)
        let earlierID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)
        let earlierTexts = ["Name a moon of Mars.", "Before restart.", "After restart."]
        func recoveries(_ reason: String) -> [[String]] {
            ((try? diagnosticEvents()) ?? []).filter {
                $0["event"] as? String == "chat.page.turn_recovered" && $0["taskID"] as? String == chatID && $0["reason"] as? String == reason
            }.map { [$0["pageID"] as? String ?? "", $0["source"] as? String ?? ""] }
        }
        func pageID(titled title: String) throws -> String {
            let pages = (try runCLI(["chat", "page", "list"], extraEnvironment: environment)["result"] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
            return try XCTUnwrap(pages.first { $0["title"] as? String == title }?["id"] as? String)
        }
        func openChat() {
            launchApp(defaultParent: nil, environmentOverrides: environment)
            element("chat-sidebar-button").click()
            XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        }

        // The turn opens a new page with close-turn; then the window closes, its daemon dies,
        // and its agent too.
        let question = "Could the iOS build run its tests in parallel?"
        startRestartChatTurn(executable, question)
        closeHeldChatTurn(executable, newTitle: "Parallel iOS tests")
        let agent = try XCTUnwrap(agentManifest(kind: "claude", service: environment)?.manifest["process"] as? [String: Any])
        attachScreenshot(named: "standalone-chat-orphan-1-turn-in-flight")
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        touch(executable + ".reattach-exit")
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(agent) }, timeout: 15), "The chat turn's agent exits without a result.")
        openChat()
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Parallel iOS tests") }, timeout: 20),
                      "The next daemon files the lost turn on the page its close-turn opened.")
        let lostPageID = try pageID(titled: "Parallel iOS tests")
        XCTAssertTrue(waitUntil({ self.restartChatPageTexts(lostPageID, environment: environment) == [question] }, timeout: 10))
        XCTAssertTrue(waitUntil({ !recoveries("reattach-lost").isEmpty }, timeout: 10), "The lost turn's filing is recorded.")
        XCTAssertEqual(recoveries("reattach-lost"), [[lostPageID, "close-turn"]])
        attachScreenshot(named: "standalone-chat-orphan-2-lost-turn-filed")

        // An answered turn an earlier build left unfiled, as in the incident: its close-turn
        // opened a page, but no page holds the turn and no close-turn record names it.
        let legacyQuestion = "Could the Android build be split into parallel steps?"
        startRestartChatTurn(executable, legacyQuestion)
        closeHeldChatTurn(executable, newTitle: "Parallel Android build")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({ self.agentManifest(kind: "claude", service: environment) == nil }, timeout: 30))
        let legacyPageID = try pageID(titled: "Parallel Android build")
        let legacyTexts = [legacyQuestion, "Before restart.", "After restart."]
        XCTAssertTrue(waitUntil({ self.restartChatPageTexts(legacyPageID, environment: environment) == legacyTexts }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        try unfileChatPageForLegacyState(legacyPageID)
        openChat()
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Parallel Android build") }, timeout: 20),
                      "The starting daemon files the unfiled turn on the page opened while it ran.")
        XCTAssertEqual(restartChatPageTexts(legacyPageID, environment: environment), legacyTexts)
        XCTAssertTrue(waitUntil({ !recoveries("startup").isEmpty }, timeout: 10), "The startup recovery is recorded.")
        XCTAssertEqual(recoveries("startup"), [[legacyPageID, "page-opened-in-turn"]])
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), earlierTexts, "The earlier page keeps only its own turn.")
        XCTAssertEqual(restartChatPageTexts(lostPageID, environment: environment), [question])
        attachScreenshot(named: "standalone-chat-orphan-3-recovered-on-startup")

        // Another restart recovers nothing more.
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        openChat()
        XCTAssertEqual(restartChatPageTexts(legacyPageID, environment: environment), legacyTexts,
                       "A later daemon never files the recovered turn twice.")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(recoveries("startup").count + recoveries("reattach-lost").count, 2, "Recovery is idempotent across restarts.")

        let seeded = sendFiledRestartChatTurn(executable, "Which step would be slowest?", environment: environment)
        XCTAssertTrue(seeded.contains(legacyQuestion) && seeded.contains("After restart."), "The recovered turn seeds its page's first session.")
        XCTAssertFalse(seeded.contains(question), "Another page's turn never reaches this page's session.")
        XCTAssertEqual(Array(restartChatPageTexts(legacyPageID, environment: environment).prefix(3)), legacyTexts)
        attachScreenshot(named: "standalone-chat-orphan-4-next-turn-seeded")
    }
    // case-contract: test_standalone_chat_codex_turns_survive_daemon_restart | A Codex standalone chat turn survives daemon restarts, each of its agent messages stored on its own as the turn streamed it. A turn still running in its shared app-server when its daemon dies is followed by the next daemon, and when it ends with close-turn --continues false that daemon files its question and answers once on the new titled page, found from the turn's durable in-flight record and close-turn record, with no page decision left pending. A turn whose daemon and app-server both die after its close-turn opened a new page is filed on that page, with what its stored transcript holds, by the next daemon as it starts, before the next send seeds; that send's fresh page session carries the recovered turn, and the recovery is recorded in diagnostics.
    func test_standalone_chat_codex_turns_survive_daemon_restart() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat(provider: "codex")
        _ = sendFiledRestartChatTurn(executable, "Name a moon of Mars.", environment: environment)
        let earlierID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)
        // Each agent message is stored on its own, as the turn streamed it.
        let answer = ["Before restart.", "After restart."]
        let earlierTexts = ["Name a moon of Mars."] + answer
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), earlierTexts, "The daemon that sent the first turn files it.")

        // The window reconnects to the next daemon, which follows the running turn; its agent
        // opens a new page with close-turn and finishes.
        let question = "Could the Android build be split into parallel steps?"
        startRestartChatTurn(executable, question)
        try killDaemon(environment: environment)
        attachScreenshot(named: "standalone-chat-codex-restart-1-turn-in-flight")
        closeHeldChatTurn(executable, newTitle: "Parallel Android build")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Parallel Android build") }, timeout: 40),
                      "The reattached Codex turn shows under the page its close-turn opened.")
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows("After restart.", belowPage: "Parallel Android build") }, timeout: 20),
                      "The window shows the reattached turn's answer under its new page.")
        var pageID = ""
        XCTAssertTrue(waitUntil({
            guard let status = self.restartChatStatus(environment), status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any], page["title"] as? String == "Parallel Android build",
                  let id = page["id"] as? String else { return false }
            pageID = id
            return self.restartChatPageTexts(id, environment: environment) == [question] + answer
        }, timeout: 20), "The daemon that followed the Codex turn files it once on the page its close-turn opened.")
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), earlierTexts, "The earlier page keeps only its own turn.")
        let filed = try diagnosticEvents().filter { $0["event"] as? String == "chat.page.reattached_turn.filed" && $0["taskID"] as? String == chatID }
        XCTAssertEqual(filed.map { [$0["pageID"] as? String ?? "", $0["signal"] as? String ?? ""] }, [[pageID, "close-turn"]],
                       "The reattached filing is recorded in diagnostics.")
        attachScreenshot(named: "standalone-chat-codex-restart-2-turn-filed-on-new-page")

        // A turn opens a new page with close-turn; then the window closes, its daemon dies, and
        // its app-server too.
        let lostQuestion = "Could the iOS build run its tests in parallel?"
        startRestartChatTurn(executable, lostQuestion)
        closeHeldChatTurn(executable, newTitle: "Parallel iOS tests")
        let server = try XCTUnwrap(agentManifest(kind: "codex", service: environment)?.manifest["process"] as? [String: Any])
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        touch(executable + ".reattach-die")
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(server) }, timeout: 15), "The Codex app-server exits with the turn unfinished.")
        launchApp(defaultParent: nil, environmentOverrides: environment)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let pages = (try runCLI(["chat", "page", "list"], extraEnvironment: environment)["result"] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
        let lostPageID = try XCTUnwrap(pages.first { $0["title"] as? String == "Parallel iOS tests" }?["id"] as? String)

        // The next daemon files the lost turn from its stored transcript as it starts, before the
        // next send seeds its page's session.
        let seeded = sendFiledRestartChatTurn(executable, "Which suite is slowest?", environment: environment)
        XCTAssertEqual(Array(restartChatPageTexts(lostPageID, environment: environment).prefix(2)), [lostQuestion, "Before restart."],
                       "The lost Codex turn is filed on the page its close-turn opened.")
        XCTAssertTrue(seeded.contains(lostQuestion) && seeded.contains("Before restart."), "The recovered turn seeds its page's first session.")
        XCTAssertFalse(seeded.contains(question), "Another page's turn never reaches this page's session.")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Parallel iOS tests") }, timeout: 20),
                      "The recovered turn shows under the page its close-turn opened.")
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows(lostQuestion, belowPage: "Parallel iOS tests") }, timeout: 20))
        let recovered = try diagnosticEvents().filter { $0["event"] as? String == "chat.page.turn_recovered" && $0["taskID"] as? String == chatID }
        XCTAssertEqual(recovered.map { [$0["pageID"] as? String ?? "", $0["source"] as? String ?? "", $0["reason"] as? String ?? ""] },
                       [[lostPageID, "close-turn", "startup"]], "The daemon's startup recovery is recorded once.")
        attachScreenshot(named: "standalone-chat-codex-restart-3-lost-turn-recovered")
    }
    // case-contract: test_standalone_chat_reattached_turn_without_close_turn_uses_fallback | A standalone chat turn that is still running when its daemon dies and then ends without close-turn is filed by the daemon that followed it on the active page, marked as a missed page signal, and handed to the background page classifier, which moves it to the new page it titles; the earlier page keeps only its own turn and nothing stays pending. When the daemon instead dies during the close-turn nudge that follows a turn without close-turn, the daemon that follows the nudge files the user's turn, never the nudge, hands it to the classifier the same way, and the chat keeps accepting sends. The missed-signal and classifier path is shared by Claude and Codex once a reattached turn ends, so one representative provider (Claude) covers this case.
    func test_standalone_chat_reattached_turn_without_close_turn_uses_fallback() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat()
        _ = sendFiledRestartChatTurn(executable, "Name a moon of Mars.", environment: environment)
        let earlierID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)

        let question = "How do I rotate a signing key?"
        startRestartChatTurn(executable, question)
        try killDaemon(environment: environment)
        attachScreenshot(named: "standalone-chat-restart-fallback-1-turn-in-flight")
        touch(executable + ".reattach-release-quiet")
        var pageTexts: [String] = []
        XCTAssertTrue(waitUntil({
            guard let status = self.restartChatStatus(environment), status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any], page["title"] as? String == "Restart fallback",
                  let id = page["id"] as? String else { return false }
            pageTexts = self.restartChatPageTexts(id, environment: environment)
            return pageTexts == [question, "Before restart.", "After restart."]
        }, timeout: 40), "The background classifier moves the reattached turn to its new page: \(pageTexts)")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Restart fallback") }, timeout: 20),
                      "The transcript shows the classifier's page above the reattached turn.")
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows("After restart.", belowPage: "Restart fallback") }, timeout: 20),
                      "The window shows the reattached turn's answer under the classifier's page.")
        XCTAssertEqual(restartChatPageTexts(earlierID, environment: environment), ["Name a moon of Mars.", "Before restart.", "After restart."])
        let events = try diagnosticEvents()
        let filed = events.filter { $0["event"] as? String == "chat.page.reattached_turn.filed" && $0["taskID"] as? String == chatID }
        XCTAssertEqual(filed.compactMap { $0["signal"] as? String }, ["missed"], "No close-turn ran, so the filing marks a missed signal.")
        XCTAssertTrue(events.contains { $0["event"] as? String == "chat.page.fallback.scheduled" && $0["taskID"] as? String == chatID },
                      "The missed signal schedules the background classifier.")
        attachScreenshot(named: "standalone-chat-restart-fallback-2-classified")

        // The next turn skips close-turn in a live daemon, which then dies during the nudge.
        let firstFallbackID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)
        let nudgedQuestion = "Which key size should I use?"
        touch(executable + ".reattach-hold-nudge")
        startRestartChatTurn(executable, nudgedQuestion)
        try? FileManager.default.removeItem(atPath: executable + ".reattach-ready")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOfFile: executable + ".reattach-ready", encoding: .utf8)) ?? "").lowercased().contains("outcome nudge")
        }, timeout: 20), "The turn without close-turn gets its nudge, which holds.")
        try killDaemon(environment: environment)
        attachScreenshot(named: "standalone-chat-restart-fallback-3-nudge-in-flight")
        touch(executable + ".reattach-release-quiet")
        var nudgedPageID = ""
        var nudgedTexts: [String] = []
        XCTAssertTrue(waitUntil({
            guard let status = self.restartChatStatus(environment), status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any], page["title"] as? String == "Restart fallback",
                  let id = page["id"] as? String, id != firstFallbackID else { return false }
            nudgedPageID = id
            nudgedTexts = self.restartChatPageTexts(id, environment: environment)
            return nudgedTexts == [nudgedQuestion, "Before restart.", "After restart."]
        }, timeout: 40), "The user's turn behind the followed nudge is filed and classified, never the nudge: \(nudgedTexts)")
        XCTAssertTrue(waitUntil({ self.chatPageSeparators("Restart fallback").count == 2 }, timeout: 20),
                      "The window shows the classifier's second page as its own separator.")
        XCTAssertTrue(waitUntil({ self.chatTranscriptShows(nudgedQuestion, belowPage: "Restart fallback") }, timeout: 20),
                      "The user's turn shows under the new page, below its separator.")
        let signals = try diagnosticEvents().filter { $0["event"] as? String == "chat.page.reattached_turn.filed" && $0["taskID"] as? String == chatID }
            .compactMap { $0["signal"] as? String }
        XCTAssertEqual(signals, ["missed", "missed"])
        _ = sendFiledRestartChatTurn(executable, "Thanks, that settles it.", environment: environment)
        XCTAssertEqual(Array(restartChatPageTexts(nudgedPageID, environment: environment).suffix(3)),
                       ["Thanks, that settles it.", "Before restart.", "After restart."], "The chat keeps accepting sends.")
        attachScreenshot(named: "standalone-chat-restart-fallback-4-chat-keeps-sending")
    }
    // case-contract: test_agent_died_without_result_is_marked_interrupted | When a Codex app-server or a Claude Code run exits without finishing its turn while no daemon is connected, the next daemon settles the task as Waiting Response with 'The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue.', keeps the conversation up to the restart, and removes the dead agent's files.
    func test_agent_died_without_result_is_marked_interrupted() throws {
        for (provider, marker) in [("codex", ".reattach-die"), ("claude", ".reattach-exit")] {
            let executable = WorkspaceFixture.root.appendingPathComponent("\(provider)-fixture-reattach").path
            if provider == "codex" { codexFixtureExecutable = executable } else { claudeFixtureExecutable = executable }
            clearReattachMarkers(executable)
            let environment = restartServiceEnvironment()
            let title = "\(provider) agent died"
            let task = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
            ])["result"] as? [String: Any])
            let taskID = try XCTUnwrap(task["id"] as? String)
            launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
            openTask(named: title)
            sendFromComposer("Die while Playhouse is down.")
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
            let agent = try XCTUnwrap(agentManifest(kind: provider, service: environment)?.manifest["process"] as? [String: Any])
            XCTAssertTrue(terminateAppAndWait(app))
            try killDaemon(environment: environment)
            touch(executable + marker)
            XCTAssertTrue(waitUntil({ !self.agentIsAlive(agent) }, timeout: 15), "The \(provider) agent exits without a result.")
            launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
            XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
            // The relaunched window may already have started a fresh Codex server (its usage read);
            // the dead agent's own manifest is what must be gone.
            XCTAssertFalse(agentManifests().contains {
                $0.kind == provider && ($0.manifest["process"] as? [String: Any])?["pid"] as? NSNumber == agent["pid"] as? NSNumber
                    && ($0.manifest["process"] as? [String: Any])?["startTime"] as? NSNumber == agent["startTime"] as? NSNumber
            }, "The dead agent's files are removed.")
            // Opening the task comes after: Codex then starts a fresh server to read its saved thread.
            openTask(named: title)
            let settled = try runCLI(["task", "get", taskID], extraEnvironment: environment)["result"] as? [String: Any]
            XCTAssertEqual(settled?["statusMessage"] as? String, Self.restartMessage)
            XCTAssertTrue(transcriptMessage("Die while Playhouse is down.").waitToExist(timeout: 10), "The conversation up to the restart is kept.")
            if provider == "codex" {
                XCTAssertTrue(transcriptMessage("Before restart.").waitToExist(timeout: 10), "Codex keeps the output its thread saved before the agent died.")
            }
            attachScreenshot(named: "\(provider)-agent-died-interrupted")
            XCTAssertTrue(terminateAppAndWait(app))
        }
    }
    // case-contract: test_stop_kills_reattached_agent | Stop works on a turn a fresh daemon reattached: for Codex it sends turn/interrupt over the reconnected socket and leaves the shared server running; for Claude it sends the interrupt with a request number past the old daemon's and then kills the run by its verified process identity and removes its folder. Either way the task settles in Waiting Response without a restart notice.
    func test_stop_kills_reattached_agent() throws {
        for provider in ["codex", "claude"] {
            let executable = WorkspaceFixture.root.appendingPathComponent("\(provider)-fixture-reattach").path
            if provider == "codex" { codexFixtureExecutable = executable } else { claudeFixtureExecutable = executable }
            clearReattachMarkers(executable)
            let environment = restartServiceEnvironment()
            let title = "\(provider) reattached stop"
            let task = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
            ])["result"] as? [String: Any])
            let taskID = try XCTUnwrap(task["id"] as? String)
            launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
            openTask(named: title)
            sendFromComposer("Run until stopped.")
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
            let run = try XCTUnwrap(agentManifest(kind: provider, service: environment))
            let agent = try XCTUnwrap(run.manifest["process"] as? [String: Any])
            try killDaemon(environment: environment)
            let stop = element("pause-response-button")
            XCTAssertTrue(waitUntil({ stop.exists && stop.isEnabled }, timeout: 30), "The window offers Stop for the reattached \(provider) turn.")
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
            attachScreenshot(named: "\(provider)-reattached-turn-stop-offered")
            stop.click()
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-interrupted") }, timeout: 15), "Stop reaches the reattached agent.")
            XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 20))
            XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment))
            if provider == "codex" {
                XCTAssertTrue(agentIsAlive(agent), "Codex stops the turn and keeps its shared server.")
            } else {
                let requestID = try String(contentsOfFile: executable + ".reattach-interrupted", encoding: .utf8)
                XCTAssertGreaterThanOrEqual(Int(requestID.split(separator: "-").last ?? "") ?? 0, 1001)
                XCTAssertTrue(waitUntil({ !self.agentIsAlive(agent) }, timeout: 15), "The stopped Claude run is killed by its verified pid.")
                XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: run.path.deletingLastPathComponent().path) }, timeout: 10))
            }
            XCTAssertTrue(terminateAppAndWait(app))
        }
    }
    // case-contract: test_turn_events_stream_to_a_watcher_that_did_not_send | `conversation watch` (conversation.events.subscribe) on a task with no running turn returns at once with watched=false, and fails for an unknown task. While a turn another caller sent is running, a watcher receives a `watching` event, the turn's live text deltas and its final `completed` history, while the sender still gets its own stream; the window streams such a turn the same way.
    func test_turn_events_stream_to_a_watcher_that_did_not_send() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-reattach").path
        claudeFixtureExecutable = executable
        clearReattachMarkers(executable)
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Watched turn", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let idle = try runCLI(["conversation", "watch", taskID])
        XCTAssertEqual((idle["result"] as? [String: Any])?["watched"] as? Bool, false, "A watch on a task with no turn ends at once.")
        let missing = try runCLI(["conversation", "watch", UUID().uuidString], expectedStatus: 3)
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Watched turn")
        // Another caller starts the turn while the window shows the task.
        let sender = try startCLIProcess(["conversation", "send", taskID, "--message", "Stream to a watcher."])
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
        XCTAssertTrue(transcriptMessage("Stream to a watcher.").waitToExist(timeout: 15), "The window shows the prompt of a turn it didn't send.")
        XCTAssertTrue(waitUntil({ self.element("pause-response-button").exists }, timeout: 15), "The window shows the turn as running.")
        attachScreenshot(named: "watched-turn-running")
        touch(executable + ".reattach-release")
        XCTAssertTrue(transcriptMessage("After restart.").waitToExist(timeout: 20), "The window streams the watched turn's text.")
        let (sent, senderEvents) = try finishCLIProcessCapturingEvents(sender)
        XCTAssertEqual(sent["ok"] as? Bool, true)
        let senderText = senderEvents.filter { $0["type"] as? String == "text_delta" }
            .compactMap { ($0["payload"] as? [String: Any])?["text"] as? String }.joined()
        XCTAssertTrue(senderText.contains("After restart."), "The sender still gets its own stream: \(senderText)")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 20), "The window ends the running state when the turn completes.")
        XCTAssertTrue(transcriptMessage("After restart.").exists, "The finished turn's answer is shown.")
        XCTAssertEqual(try historyTexts(taskID: taskID).filter { $0 == "After restart." }.count, 1)
        attachScreenshot(named: "watched-turn-finished")
    }
    // case-contract: test_untracked_agent_process_is_stopped_on_startup | On a daemon's first request for a data folder, a process whose standard streams point into the folder's Claude or Codex run directories but that no run or server manifest accounts for is stopped, while a process writing into a run or server whose spawn is still being recorded is left alone.
    func test_untracked_agent_process_is_stopped_on_startup() throws {
        let runs = dataDirectory.appendingPathComponent("provider-runs", isDirectory: true)
        let codexRuns = dataDirectory.appendingPathComponent("codex-runs", isDirectory: true)
        for folder in ["stray", "young"] {
            try FileManager.default.createDirectory(at: runs.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: codexRuns, withIntermediateDirectories: true)
        let environment = restartServiceEnvironment()
        let service = try XCTUnwrap(environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"])
        func sleeper(writingTo output: URL) throws -> Process {
            FileManager.default.createFile(atPath: output.path, contents: Data())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.standardOutput = try FileHandle(forWritingTo: output)
            try process.run()
            return process
        }
        let stray = try sleeper(writingTo: runs.appendingPathComponent("stray/agent.out"))
        let young = try sleeper(writingTo: runs.appendingPathComponent("young/agent.out"))
        let codexStray = try sleeper(writingTo: codexRuns.appendingPathComponent("stray.log"))
        let codexYoung = try sleeper(writingTo: codexRuns.appendingPathComponent("young.log"))
        defer {
            for process in [stray, young, codexStray, codexYoung] where process.isRunning { process.terminate() }
        }
        // A spawn its daemon is still recording: a manifest with no identity yet.
        let manifest: [String: Any] = [
            "version": 1, "serviceName": service, "sessionID": "young",
            "state": "spawning", "createdAt": Date().timeIntervalSinceReferenceDate, "mode": "default",
            "consumedOffset": 0, "maxRequestID": 0, "pendingRequestIDs": [String](), "answeredRequestIDs": [String](), "writeInProgress": false,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: runs.appendingPathComponent("young/run.json"))
        // The same for a Codex server: its log is named by the manifest's key hash.
        let codexManifest: [String: Any] = [
            "version": 1, "serviceName": service, "keyHash": "young", "keyParts": [String](), "state": "spawning",
            "createdAt": Date().timeIntervalSinceReferenceDate, "socketPath": codexRuns.appendingPathComponent("young.sock").path,
            "resolvedExecutablePath": "/usr/bin/true", "flags": [String](), "threads": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: codexManifest).write(to: codexRuns.appendingPathComponent("young.json"))
        // The window's first requests start the daemon, which sweeps the run folders.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ !stray.isRunning }, timeout: 20), "A Claude run process no manifest accounts for is stopped.")
        XCTAssertTrue(waitUntil({ !codexStray.isRunning }, timeout: 20), "A Codex server process no manifest accounts for is stopped.")
        XCTAssertTrue(young.isRunning, "A Claude spawn still being recorded is left alone.")
        XCTAssertTrue(codexYoung.isRunning, "A Codex spawn still being recorded is left alone.")
    }
    // case-contract: test_agent_finished_while_daemon_was_down_shows_result | A Claude Code turn that writes its result while no daemon is running is finished by the next daemon from the run's log: the task leaves In Progress through the normal outcome path without a restart notice, and the result written during the downtime appears exactly once.
    func test_agent_finished_while_daemon_was_down_shows_result() throws {
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-reattach").path
        claudeFixtureExecutable = executable
        clearReattachMarkers(executable)
        let environment = restartServiceEnvironment()
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude finished while down", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Claude finished while down")
        sendFromComposer("Finish while Playhouse is down.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20))
        let run = try XCTUnwrap(agentManifest(kind: "claude", service: environment))
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)
        touch(executable + ".reattach-release-quiet")
        let log = run.path.deletingLastPathComponent().appendingPathComponent("agent.out").path
        XCTAssertTrue(waitUntil({ ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("\"type\": \"result\"") }, timeout: 15))
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        openTask(named: "Claude finished while down")
        XCTAssertTrue(transcriptMessage("After restart.").waitToExist(timeout: 30), "The result written during the restart is shown.")
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response", environment: environment, timeout: 40))
        XCTAssertFalse((try taskRecord(id: taskID)?["statusMessage"] as? String ?? "").contains("restarting"))
        XCTAssertEqual(try historyTexts(taskID: taskID, environment: environment).filter { $0 == "After restart." }.count, 1)
        attachScreenshot(named: "claude-finished-while-down")
    }
    // case-contract: test_codex_stop_rejection_restores_active_task | If Codex rejects turn/interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; in the window Continue replaces Stop at once and gives way to Stop again when the provider refuses; releasing the fixture lets the original turn complete normally into Waiting Response.
    func test_codex_stop_rejection_restores_active_task() throws {
        try exerciseRejectedStop(provider: "codex", title: "Codex rejected stop")
    }
    // case-contract: test_claude_stop_rejection_restores_active_task | If Claude rejects its session control interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; in the window Continue replaces Stop at once and gives way to Stop again when the provider refuses; releasing the fixture lets the original turn complete normally into Waiting Response.
    func test_claude_stop_rejection_restores_active_task() throws {
        try exerciseRejectedStop(provider: "claude", title: "Claude rejected stop")
    }
    // case-contract: test_conversation_provider_selection_persists_and_validates | New tasks use the default provider from settings, which starts as Codex and rejects unknown providers, and task create can choose a provider explicitly and saves a --prompt description without starting the task, rejecting a blank or missing prompt; the UI shows that task in Backlog with the description unsent in its composer. A task without a conversation switches providers immediately; provider choice persists across fresh CLI/XPC reads and an app relaunch. Each provider's selected model becomes the default for conversations without an override; conversation-specific selections persist across provider switches and fresh CLI/XPC reads without reusing the other provider's model. Unknown providers and Done-task switches are rejected, and history has no provider boundary. A Claude task names Claude in the empty conversation, hides Goal mode, and rejects Goal changes through CLI/XPC. Switching a task's provider also updates the sticky default provider for new tasks and chats.
    func test_conversation_provider_selection_persists_and_validates() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let claudeExecutable = dataDirectory.appendingPathComponent("claude-fixture-provider-selection")
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
        let settings = try XCTUnwrap(try runCLI(["settings", "get"])["result"] as? [String: Any])
        XCTAssertEqual(settings["defaultProvider"] as? String, "codex", "Existing installs keep Codex as the default provider.")
        let unknownDefault = try runCLI(["settings", "set-default-provider", "gemini"], expectedStatus: 2)
        XCTAssertEqual((unknownDefault["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        _ = try runCLI(["task", "create", "--title", "Unknown provider UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "gemini"], expectedStatus: 2)

        try createTaskFixture(title: "Provider choice UI", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Provider choice UI")
        XCTAssertEqual(try taskRecord(id: taskID)?["conversationProvider"] as? String, "codex")
        openTask(named: "Provider choice UI")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(providerMenu.waitToExist(timeout: 10), "The composer should offer a provider picker.")
        XCTAssertTrue(waitUntil({ providerMenu.label.contains("Codex") && providerMenu.isEnabled }, timeout: 10))
        XCTAssertTrue(app.staticTexts["Send a message to Codex · Luna."].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "model", taskID, "set", "codex-choice"])

        element("conversation-provider-menu").click()
        let claudeChoice = app.menuItems["conversation-provider-claude"]
        XCTAssertTrue(claudeChoice.waitToExist(timeout: 5))
        claudeChoice.click()
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Claude") }, timeout: 10), "A task without a conversation switches immediately.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["conversationProvider"] as? String) == "claude" }, timeout: 10))
        XCTAssertTrue(waitUntil({
            guard let settings = try? self.runCLI(["settings", "get"]) else { return false }
            return (settings["result"] as? [String: Any])?["defaultProvider"] as? String == "claude"
        }, timeout: 10), "Switching a task's provider updates the sticky default for new tasks and chats.")
        try createTaskFixture(title: "Provider follows switch UI", roots: [fixture.primary.path])
        let providerFollowsSwitchTaskID = try self.taskID(named: "Provider follows switch UI")
        XCTAssertEqual(try taskRecord(id: providerFollowsSwitchTaskID)?["conversationProvider"] as? String, "claude", "A new task defaults to the provider last chosen in any conversation, not Codex.")
        let claudeModelBeforeSelection = try runCLI(["conversation", "model", taskID])
        XCTAssertEqual((claudeModelBeforeSelection["result"] as? [String: Any])?["modelID"] as? String, nil, "Claude must not inherit the Codex model selection.")
        _ = try runCLI(["conversation", "model", taskID, "set", "claude-choice"])
        XCTAssertTrue(waitUntil({
            let prompt = self.element("model-prompt")
            return prompt.exists && self.accessibleLabelOrValue(of: prompt).contains("Send a message to Claude")
        }, timeout: 10), "The empty conversation names Claude.")
        XCTAssertFalse(element("provider-boundary-claude").exists, "Switching before any conversation records no boundary.")
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").isEnabled }, timeout: 10))
        element("conversation-provider-menu").click()
        XCTAssertTrue(app.menuItems["conversation-provider-codex"].waitToExist(timeout: 5))
        app.menuItems["conversation-provider-codex"].click()
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Codex") }, timeout: 10))
        let switchedCodexModelPicker = element("model-picker-menu")
        XCTAssertTrue(waitUntil({ switchedCodexModelPicker.label.contains("codex-choice") }, timeout: 10), "Switching back to Codex should restore its visible model selection.")
        XCTAssertEqual((try runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String, "codex-choice")
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").isEnabled }, timeout: 10))
        element("conversation-provider-menu").click()
        XCTAssertTrue(app.menuItems["conversation-provider-claude"].waitToExist(timeout: 5))
        app.menuItems["conversation-provider-claude"].click()
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Claude") }, timeout: 10))
        let switchedClaudeModelPicker = element("model-picker-menu")
        XCTAssertTrue(waitUntil({ switchedClaudeModelPicker.label.contains("claude-choice") }, timeout: 10), "Switching back to Claude should restore its visible model selection.")
        XCTAssertEqual((try runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String, "claude-choice")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertEqual((history["providerBoundaries"] as? [Any])?.count, 0)

        XCTAssertTrue(element("conversation-plan-button").waitToExist(timeout: 5), "Claude tasks show the Plan button.")
        XCTAssertFalse(element("conversation-goal-button").exists, "Claude tasks hide the Goal button.")
        let goal = try runCLI(["conversation", "goal", taskID, "set", "--text", "Ship it"], expectedStatus: 1)
        XCTAssertEqual((goal["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        XCTAssertTrue(((goal["error"] as? [String: Any])?["message"] as? String ?? "").contains("Goals are available only in Codex conversations"))

        element("back-to-board-button").click()
        relaunchApp()
        openTask(named: "Provider choice UI")
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Claude") }, timeout: 10), "The provider choice persists across an app relaunch.")
        XCTAssertTrue(app.staticTexts["Send a message to Claude."].waitToExist(timeout: 10))
        element("back-to-board-button").click()

        _ = try runCLI(["settings", "set-default-provider", "claude"])
        let explicit = try XCTUnwrap(try runCLI(["task", "create", "--title", "Explicit Codex UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex"])["result"] as? [String: Any])
        XCTAssertEqual(explicit["conversationProvider"] as? String, "codex", "task create can choose a provider explicitly.")
        let prompted = try XCTUnwrap(try runCLI(["task", "create", "--title", "Prompted UI", "--root", fixture.primary.path, "--prompt", "Full description of the work"])["result"] as? [String: Any])
        XCTAssertEqual(prompted["savedPrompt"] as? String, "Full description of the work", "task create --prompt saves the description.")
        XCTAssertEqual(prompted["status"] as? String, "Backlog", "A prompt on create must not start the task.")
        XCTAssertNil(prompted["pendingSubmittedPrompt"], "A prompt on create must not be submitted.")
        assertTaskVisible("Prompted UI", inColumn: "Backlog")
        openTask(named: "Prompted UI")
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String) == "Full description of the work" }, timeout: 10),
                      "The created task's composer should hold its saved description.")
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10), "A description saved on create must not have been sent.")
        attachScreenshot(named: "Task created with a prompt shows its description unsent in the composer")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        XCTAssertEqual(try taskRecord(id: try XCTUnwrap(prompted["id"] as? String))?["status"] as? String, "Backlog", "Opening the task must not start it.")
        let blankPrompt = try runCLI(["task", "create", "--title", "Blank prompt UI", "--root", fixture.primary.path, "--prompt", "   "], expectedStatus: 2)
        XCTAssertEqual((blankPrompt["error"] as? [String: Any])?["code"] as? String, "invalid_argument", "A blank --prompt is rejected.")
        let missingPrompt = try runCLI(["task", "create", "--title", "Missing prompt UI", "--root", fixture.primary.path], expectedStatus: 2)
        XCTAssertEqual((missingPrompt["error"] as? [String: Any])?["code"] as? String, "invalid_argument", "A missing --prompt is rejected.")
        openNewTaskConversation()
        XCTAssertTrue(waitUntil({ self.element("conversation-provider-menu").label.contains("Claude") }, timeout: 10), "New tasks use the default provider from settings.")
        closeConversationRepositoryPicker()
        element("back-to-board-button").click()

        try createTaskFixture(title: "Provider done UI", roots: [fixture.secondary.path])
        let doneTaskID = try self.taskID(named: "Provider done UI")
        _ = try runCLI(["conversation", "provider", doneTaskID, "set", "codex"])
        openTask(named: "Provider done UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Provider done UI")
        element("back-to-board-button").click()
        moveTaskToDone("Provider done UI")
        element("done-archive-button").click()
        let archived = element("done-archive-task-\(doneTaskID)")
        XCTAssertTrue(archived.waitToExist(timeout: 10))
        archived.click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-provider-menu").waitToExist(timeout: 10))
        XCTAssertFalse(element("conversation-provider-menu").isEnabled, "A Done task's conversation offers no provider switch.")
        let doneSwitch = try runCLI(["conversation", "provider", doneTaskID, "set", "claude"], expectedStatus: 2)
        XCTAssertTrue(((doneSwitch["error"] as? [String: Any])?["message"] as? String ?? "").contains("Done tasks are closed"))
        XCTAssertEqual(try taskRecord(id: doneTaskID)?["conversationProvider"] as? String, "codex")
    }
}

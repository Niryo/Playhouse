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
    func exerciseStopDuringThinking(provider: String, title: String) throws {
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let fixtureName = provider == "codex" ? "codex-fixture-hold-interrupt" : "claude-fixture-ui"
        let executable = (provider == "codex" ? dataDirectory : WorkspaceFixture.root).appendingPathComponent(fixtureName).path
        if provider == "codex" {
            try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent(fixtureName), to: URL(fileURLWithPath: executable))
            try "Playhouse test owns this Codex protocol fixture (v1).\n".write(
                to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"),
                atomically: true, encoding: .utf8
            )
        }
        let ready = URL(fileURLWithPath: executable + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable + ".interrupt-received")
        let release = URL(fileURLWithPath: executable + ".interrupt-release")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: received)
        try? FileManager.default.removeItem(at: release)
        if provider == "codex" { codexFixtureExecutable = executable }
        else { claudeFixtureExecutable = executable }

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "\(provider) should be actively thinking before Stop is clicked.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        let threadKey = provider == "codex" ? "codexThreadID" : "claudeSessionID"
        let threadID = try XCTUnwrap(try taskRecord(id: taskID)?[threadKey] as? String, "The thinking \(provider) turn should have a native conversation ID.")
        let thinking = try XCTUnwrap(try runCLI(["conversation", "runtime"])["result"] as? [String: Any])
        XCTAssertTrue((thinking["activeThreadIDs"] as? [String] ?? []).contains(threadID), "The daemon should report the window's thinking turn as active.")
        XCTAssertTrue((thinking["interruptibleThreadIDs"] as? [String] ?? []).contains(threadID), "The daemon should report the window's thinking turn as interruptible.")

        let stopActivity = element("codex-activity-disclosure")
        XCTAssertTrue(stopActivity.waitToExist(timeout: 10), "A thinking turn should surface its activity section.")
        XCTAssertTrue(waitUntil({ stopActivity.value as? String == "Expanded, down chevron" }, timeout: 10),
                      "A thinking turn should show its work instead of hiding it behind Working for.")
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.isEnabled }, timeout: 10), "Stop should be enabled while the provider turn is active, before any text is written.")
        stop.click()
        XCTAssertTrue(waitUntil({ (try? taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 5), "The task should move to Waiting Response immediately after Stop.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        let waitingColumn = element("column-waiting-response")
        let waitingCard = waitingColumn.buttons["task-card-\(taskID.uppercased())"]
        XCTAssertTrue(waitingCard.waitToExist(timeout: 5), "The visible board should place the stopped task in Waiting Response before interrupt acknowledgment.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10), "\(provider) should receive its native interrupt.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response", "The task should move before the provider acknowledges the interrupt.")
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        clickTaskCardTitle(waitingCard)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 15), "The stopped turn should reset the composer to its resumable state.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: taskID)?["statusMessage"] as? String, "A user-requested stop should not leave a failure reason.")
        // A user-initiated Stop settles with no final answer and no Blocked reason,
        // distinct from both the answered and the interrupted-with-reason folds
        // covered elsewhere. The fixture's reported activity keeps the section
        // mounted, so the fold here is distinguishable from the section never
        // having rendered.
        let reopenedActivity = element("codex-activity-disclosure")
        XCTAssertTrue(waitUntil({ reopenedActivity.value as? String == "Collapsed, right chevron" }, timeout: 10),
                      "A user-initiated Stop should fold its activity section away once the daemon reports the turn no longer active.")
        XCTAssertTrue(reopenedActivity.exists, "The stopped turn's activity section should stay available, just folded.")
        let settled = try XCTUnwrap(try runCLI(["conversation", "runtime"])["result"] as? [String: Any])
        XCTAssertFalse((settled["activeThreadIDs"] as? [String] ?? []).contains(threadID), "A stopped turn is no longer active in the daemon.")
        XCTAssertTrue((settled["interruptedThreadIDs"] as? [String] ?? []).contains(threadID), "The daemon should remember that the window paused the turn.")
        if provider == "codex" {
            relaunchApp()
            openTask(named: title)
            XCTAssertTrue(app.staticTexts["message-time-item_user_fixture_1"].waitForExistence(timeout: 10),
                          "The observed message time survives interruption and relaunch.")
            attachScreenshot(named: "Interrupted Codex message timestamp")
            attachElementScreenshot(app.staticTexts["message-time-item_user_fixture_1"], named: "Interrupted Codex timestamp detail")
        }
    }
    func exerciseRejectedStop(provider: String, title: String) throws {
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider,
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let fixtureName = provider == "codex" ? "codex-fixture-hold-reject-interrupt" : "claude-fixture-hold-reject-interrupt"
        let executable = WorkspaceFixture.root.appendingPathComponent(fixtureName).path
        let ready = URL(fileURLWithPath: executable + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable + ".interrupt-received")
        let reject = URL(fileURLWithPath: executable + ".interrupt-reject")
        let release = URL(fileURLWithPath: executable + ".interrupt-release")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: received)
        try? FileManager.default.removeItem(at: reject)
        try? FileManager.default.removeItem(at: release)
        if provider == "codex" { codexFixtureExecutable = executable }
        else { claudeFixtureExecutable = executable }

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "\(provider) should be thinking before the rejected Stop.")
        element("pause-response-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10), "\(provider) should receive its native interrupt before rejecting it.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response", "The optimistic pause should persist while rejection is pending.")
        try Data("reject interrupt\n".utf8).write(to: reject)
        let stopError = element("codex-chat-error")
        XCTAssertTrue(stopError.waitToExist(timeout: 10), "The UI should report the provider's rejected interrupt.")
        XCTAssertTrue(stopError.label.localizedCaseInsensitiveContains("rejected"), "The visible error should explain that the provider rejected Stop.")
        XCTAssertTrue(waitUntil({ (try? taskRecord(id: taskID)?["status"] as? String) == "In Progress" }, timeout: 5), "A rejected stop should restore In Progress while the turn remains active.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        let activeColumn = element("column-in-progress")
        let activeCard = activeColumn.buttons["task-card-\(taskID.uppercased())"]
        XCTAssertTrue(activeCard.waitToExist(timeout: 5), "The visible board should keep the still-running task in In Progress.")
        try Data("finish active turn\n".utf8).write(to: release)
        XCTAssertTrue(waitUntil({ (try? taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 15), "The original turn should complete normally and return the task for review.")
        let waitingColumn = element("column-waiting-response")
        XCTAssertTrue(waitingColumn.buttons["task-card-\(taskID.uppercased())"].waitToExist(timeout: 8), "The visible board should show the naturally completed task awaiting review.")
    }
    func openSideChatOnReply(
        title: String, beforeOpening: (String) throws -> Void = { _ in }
    ) throws -> (taskID: String, reply: XCUIElement, bubble: XCUIElement) {
        try createTaskFixture(title: title, roots: [fixture.primary.path])
        let taskID = try taskID(named: title)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Explain the design of the parser."])
        try beforeOpening(taskID)
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let reply = try XCTUnwrap(ordinaryMessages(try XCTUnwrap(history["messages"] as? [[String: Any]]))
            .last { ($0["role"] as? String) == "assistant" })
        let replyID = try XCTUnwrap(reply["id"] as? String)
        openTask(named: title)
        let replyText = element("assistant-message-\(replyID)").descendants(matching: .staticText).firstMatch
        XCTAssertTrue(replyText.waitToExist(timeout: 10), "The task's reply should be visible.")
        XCTAssertTrue(waitForStableFrame(replyText), "The reply should settle before its text is selected.")
        replyText.click()
        replyText.typeKey("a", modifierFlags: .command)
        // The reply is one short line, so its hint centres on those few characters, not the text view.
        let bubble = try waitForSideChatBubble(at: replyText, hintScreenshot: "Side chat hint above the selected reply")
        XCTAssertFalse(app.buttons["add-comment-to-selection-button"].exists, "The bubble replaces the Add comment hint.")
        return (taskID, replyText, bubble)
    }
    func sendSideChatMessage(_ message: String, answerIndex index: Int, containing expected: String) -> XCUIElement {
        let input = element("side-chat-input")
        XCTAssertTrue(input.waitToExist(timeout: 5))
        input.click()
        input.typeText(message + "\r")
        let question = element("side-chat-user-message-\(index - 1)")
        XCTAssertTrue(question.waitToExist(timeout: 10), "The side chat should show the question it sent.")
        XCTAssertEqual(question.label, message)
        let answer = element("side-chat-assistant-message-\(index)")
        XCTAssertTrue(waitUntil({ answer.exists && answer.label.contains(expected) }, timeout: 30),
                      "The side chat should answer with \(expected); it showed \(answer.exists ? answer.label : "nothing").")
        XCTAssertTrue((input.value as? String ?? "").isEmpty, "Sending should clear the side chat composer.")
        return answer
    }
    func assertTurnProgressReachesReopenedConversation(provider: String, fixtureSource: String, executableName: String, activityID: String, modelID: String? = nil) throws {
        let display = provider == "claude" ? "Claude" : "Codex"
        let source = WorkspaceFixture.root.appendingPathComponent(fixtureSource)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        let executable = dataDirectory.appendingPathComponent(executableName)
        try copyFixtureFile(at: source, to: executable)
        if provider == "claude" {
            claudeFixtureExecutable = executable.path
            try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
                .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        } else {
            codexFixtureExecutable = executable.path
            try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
                .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        }
        let started = URL(fileURLWithPath: executable.path + ".follow-turn-started")
        let resume = URL(fileURLWithPath: executable.path + ".follow-turn-continue")
        let ready = URL(fileURLWithPath: executable.path + ".follow-turn-ready")
        let release = URL(fileURLWithPath: executable.path + ".follow-turn-release")
        defer {
            try? Data("Release after assertion failure.\n".utf8).write(to: resume)
            try? Data("Release after assertion failure.\n".utf8).write(to: release)
        }
        let title = "\(display) followed turn"
        let prompt = "Please follow-active-turn."
        let progressText = "\(display) is partway through the followed turn."
        let finalText = "\(display) finished the followed turn."
        func visibleText(_ text: String) -> XCUIElement {
            app.groups.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider])
        if let modelID {
            _ = try runCLI(["conversation", "model", try taskID(named: title), "set", modelID])
        }
        func fixtureHistory() -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return history
        }
        func providerResumeCount() -> Int { fixtureHistory()["threadResumeCount"] as? Int ?? 0 }
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText(prompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: started.path) }, timeout: 20), "The \(display) fixture should hold the turn before any output.")
        if let modelID {
            let turns = fixtureHistory()["turns"] as? [[String: Any]] ?? []
            XCTAssertEqual(turns.last?["modelID"] as? String, modelID, "The window's send should run the turn with the task's selected model.")
        }
        // Counted from before the reopened view's first load, which is already a mid-turn read.
        let resumesBeforeReopen = providerResumeCount()

        // A reopened conversation is a new view that no longer reads the send's stream.
        element("back-to-board-button").click()
        openTask(named: title)
        XCTAssertTrue(transcriptMessage(prompt).waitToExist(timeout: 10), "The reopened conversation should load the running turn's prompt.")
        XCTAssertFalse(visibleText(progressText).exists, "No progress exists before the fixture continues.")
        let taskID = try taskID(named: title)
        func revision() throws -> Int {
            let runtime = try runCLI(["conversation", "runtime"])["result"] as? [String: Any]
            return (runtime?["conversationRevisions"] as? [String: Int])?[taskID] ?? 0
        }
        let quietRevision = try revision()

        try Data("Show progress.\n".utf8).write(to: resume)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20), "The \(display) fixture should hold the turn while its progress is visible.")
        XCTAssertTrue(visibleText(progressText).waitToExist(timeout: 10), "The reopened conversation should show the running turn's commentary without waiting for the turn to end.")
        let runningRow = element("codex-activity-row-\(activityID)")
        XCTAssertTrue(runningRow.waitToExist(timeout: 10), "The reopened conversation should show the running tool row.")
        XCTAssertTrue(runningRow.label.contains("In progress"), "The tool row should still be running while the turn holds.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "The turn should still be held while its progress shows.")
        XCTAssertFalse(visibleText(finalText).exists, "The final answer must not appear before the turn finishes.")
        let progressedRevision = try revision()
        XCTAssertGreaterThan(progressedRevision, quietRevision, "The running turn's progress should raise the task's conversation revision.")
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let texts = (history?["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertTrue(texts.contains(progressText), "Mid-turn history should hold the running turn's commentary.")
        XCTAssertFalse(texts.contains(finalText), "Mid-turn history must not hold a final answer yet.")
        let activity = (history?["activities"] as? [[String: Any]] ?? []).first { $0["id"] as? String == activityID }
        XCTAssertEqual(activity?["status"] as? String, "inProgress", "Mid-turn history should hold the running tool activity.")
        XCTAssertEqual(providerResumeCount(), resumesBeforeReopen, "Following the running turn must read its thread as loaded, not resume it with history's default model.")

        try Data("Finish the turn.\n".utf8).write(to: release)
        XCTAssertTrue(visibleText(finalText).waitToExist(timeout: 30), "The reopened conversation should show the final answer once the turn settles.")
        XCTAssertTrue(waitUntil({ ((try? revision()) ?? 0) > progressedRevision }, timeout: 10), "The revision should rise again when the turn ends.")
    }
    func assertTranscriptEndsWithoutOverscroll(
        question: XCUIElement, lastRow: XCUIElement, in scrollView: XCUIElement, turnFitsViewport: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<5 { scrollView.scroll(byDeltaX: 0, deltaY: -600) }
        var settledBottom = CGFloat.nan
        _ = waitUntil({
            let bottom = lastRow.frame.maxY
            defer { settledBottom = bottom }
            return bottom == settledBottom
        }, timeout: 3)
        let viewport = scrollView.frame
        XCTAssertTrue(lastRow.exists && viewport.insetBy(dx: 0, dy: -2).contains(lastRow.frame),
                      "The bottom of the transcript should show its last row; row=\(lastRow.frame), viewport=\(viewport).",
                      file: file, line: line)
        if turnFitsViewport {
            XCTAssertTrue(question.exists && question.frame.minY >= viewport.minY - 2 && question.frame.minY <= viewport.minY + 120,
                          "Scrolled to the bottom, a newest turn that fits should keep its question pinned near the top, with no blank space opening above or below it; question=\(question.frame), row=\(lastRow.frame), viewport=\(viewport).",
                          file: file, line: line)
        } else {
            // The content padding and any trailing row sit below the last row; the overscroll
            // this guards against opened most of a viewport.
            XCTAssertLessThanOrEqual(viewport.maxY - lastRow.frame.maxY, 100,
                                     "Scrolled to the bottom, a turn taller than the viewport should end at its last row instead of opening blank space below; row=\(lastRow.frame), viewport=\(viewport).",
                                     file: file, line: line)
        }
    }
    func assertEarlierTurnToolCallsRenderInline(provider: String, executableName: String, callIDs: [String], summaries: [String]) throws {
        let display = provider == "claude" ? "Claude" : "Codex"
        let source = WorkspaceFixture.root.appendingPathComponent(provider == "claude" ? "claude-fixture-ui" : "codex-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        let executable = dataDirectory.appendingPathComponent(executableName)
        try copyFixtureFile(at: source, to: executable)
        if provider == "claude" {
            claudeFixtureExecutable = executable.path
            try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
                .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        } else {
            codexFixtureExecutable = executable.path
            try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
                .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        }
        let title = "\(display) timeline tools"
        let introText = "I'll check the repository status first."
        let middleText = "The status is clean. Next I'll list the files and run the check."
        func visibleText(_ text: String) -> XCUIElement {
            app.groups.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        func text(of element: XCUIElement) -> String {
            [element.label, element.value as? String ?? ""].joined(separator: " ")
        }

        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", provider])
        let taskID = try taskID(named: title)
        openTask(named: title)
        func turnIsActive() -> Bool {
            let runtime = (try? self.runCLI(["conversation", "runtime"]))?["result"] as? [String: Any]
            let task = (try? self.runCLI(["task", "get", taskID]))?["result"] as? [String: Any]
            guard let thread = task?[provider == "claude" ? "claudeSessionID" : "codexThreadID"] as? String else { return true }
            return (runtime?["activeThreadIDs"] as? [String] ?? []).contains(thread)
        }
        let composer = element("message-composer")
        for (index, message) in ["Please show-tool-calls-inline.", "Please reply simply."].enumerated() {
            XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
            composer.click()
            composer.typeText(message)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                let history = (try? self.runCLI(["conversation", "history", taskID]))?["result"] as? [String: Any]
                let messages = history?["messages"] as? [[String: Any]] ?? []
                guard let user = messages.lastIndex(where: { $0["role"] as? String == "user" && $0["text"] as? String == message }) else { return false }
                return messages[(user + 1)...].contains { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
                    && !turnIsActive()
            }, timeout: 40), "The \(display) fixture turn \(index + 1) should finish with an answer.")
            if index == 0 {
                XCTAssertFalse(element("conversation-tool-call-\(callIDs[0])").waitToExist(timeout: 2),
                               "While its turn is the latest, a call stays in Worked for instead of rendering inline.")
            }
        }

        let scrollView = element("conversation-scroll-view")
        XCTAssertTrue(revealWholeTranscript(), "The earlier turn should load as the reader scrolls up.")
        let rows = callIDs.map { element("conversation-tool-call-\($0)") }
        for row in rows {
            XCTAssertTrue(scrollTranscriptUntilExists(row), "The earlier turn's call should render inline: \(row.identifier)")
        }
        let intro = visibleText(introText)
        let middle = visibleText(middleText)
        XCTAssertTrue(intro.exists && middle.exists, "The commentary on either side of the calls should render as messages.")
        XCTAssertTrue(scrollFullyIntoView(rows[0], in: scrollView))
        XCTAssertLessThan(intro.frame.minY, rows[0].frame.minY, "The first call should follow the message written before it.")
        XCTAssertLessThan(rows[0].frame.minY, middle.frame.minY, "The first call should come before the next message.")
        for (earlier, later) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(earlier.frame.minY, later.frame.minY, "Calls should render in the order they ran.")
        }
        XCTAssertLessThan(middle.frame.minY, rows[1].frame.minY, "Later calls should follow the second message.")

        XCTAssertTrue(rows[0].label.contains("Bash") && rows[0].label.contains("Completed"), rows[0].label)
        XCTAssertTrue(text(of: element("conversation-tool-call-name-\(callIDs[0])")).contains("Bash"))
        XCTAssertTrue(text(of: element("conversation-tool-call-summary-\(callIDs[0])")).contains(summaries[0]))
        XCTAssertTrue(text(of: element("conversation-tool-call-input-\(callIDs[0])")).contains("git status --short && echo fixture-status-done"),
                      "The IN block should show the exact command.")
        XCTAssertTrue(text(of: element("conversation-tool-call-output-\(callIDs[0])")).contains("fixture-status-done"),
                      "The OUT block should show what the command returned.")
        XCTAssertTrue(rows[2].label.contains("Failed"), "A failing command should render as failed: \(rows[2].label)")
        XCTAssertTrue(text(of: element("conversation-tool-call-input-\(callIDs[2])")).contains("exit 3"))
        XCTAssertFalse(element("conversation-tool-call-input-\(callIDs[3])").exists, "An MCP call's arguments must stay private.")
        XCTAssertFalse(element("conversation-tool-call-output-\(callIDs[3])").exists, "An MCP call's raw result must stay private.")
        for privateText in ["timeline-private-argument", "timeline-private-result"] {
            XCTAssertEqual(rows[3].descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", privateText, privateText
            )).count, 0, "The MCP row must not show its private arguments or result.")
            XCTAssertFalse(rows[3].label.contains(privateText))
        }
        attachScreenshot(named: "\(display) earlier turn tool calls inline")

        let listingOutput = element("conversation-tool-call-output-\(callIDs[1])")
        XCTAssertTrue(scrollFullyIntoView(rows[1], in: scrollView))
        let collapsedHeight = listingOutput.frame.height
        XCTAssertFalse(element("conversation-tool-call-toggle-\(callIDs[0])").exists, "A short call has nothing more to show.")
        let toggle = element("conversation-tool-call-toggle-\(callIDs[1])")
        XCTAssertTrue(toggle.waitToExist(timeout: 5), "A call whose output runs past the clipped lines can expand.")
        toggle.click()
        XCTAssertTrue(waitUntil({ listingOutput.frame.height > collapsedHeight + 10 }, timeout: 5),
                      "Expanding should show every output line, not just the clipped ones.")
        XCTAssertTrue(text(of: listingOutput).contains("fixture-four.txt"))
        attachScreenshot(named: "\(display) tool call output expanded")

        let firstStep = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", "git status --short was clean."
        )).firstMatch
        XCTAssertTrue(firstStep.waitToExist(timeout: 5),
                      "A numbered list right under a paragraph line should render as list items, with its inline code text unchanged.")
        XCTAssertFalse(firstStep.label.contains("Here is what ran"), "The list item should not be merged into the paragraph above it.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", "The check exited with code 3."
        )).firstMatch.exists, "The second numbered item should render as its own list item.")
        let bulletItem = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-list-item-", "Inline code is tinted"
        )).firstMatch
        XCTAssertTrue(bulletItem.exists, "The answer's bullets should render as list items.")
        XCTAssertTrue(scrollFullyIntoView(bulletItem, in: scrollView))
        XCTAssertTrue(scrollFullyIntoView(firstStep, in: scrollView))
        attachScreenshot(named: "\(display) answer with inline code and lists")

        element("back-to-board-button").click()
        openTask(named: title)
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load the earlier turn as the reader scrolls up.")
        XCTAssertTrue(scrollTranscriptUntilExists(element("conversation-tool-call-\(callIDs[0])")),
                      "The earlier turn's calls should still render inline after reopening the task.")
        XCTAssertTrue(text(of: element("conversation-tool-call-input-\(callIDs[0])")).contains("git status --short"))
    }
    func expandLatestWorkedFor() -> Bool {
        let disclosure = element("codex-activity-disclosure")
        guard waitUntil({ disclosure.exists && disclosure.label.hasPrefix("Worked for") }, timeout: 15) else { return false }
        if (disclosure.value as? String ?? "").hasPrefix("Collapsed") { disclosure.click() }
        return element("codex-activity-details").waitToExist(timeout: 5)
    }
    func sendLaterTurnAndAssertNudgedCallInline(taskID: String, callID: String, visibleTexts: [String]) throws {
        let message = "Thanks, that's all."
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText(message)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            let history = (try? self.runCLI(["conversation", "history", taskID]))?["result"] as? [String: Any]
            let messages = history?["messages"] as? [[String: Any]] ?? []
            guard let user = messages.lastIndex(where: { $0["role"] as? String == "user" && $0["text"] as? String == message }) else { return false }
            return messages[(user + 1)...].contains { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
                && self.noTurnIsRunning()
        }, timeout: 60), "The later ordinary turn should finish with an answer.")
        XCTAssertTrue(revealWholeTranscript(), "The earlier nudged turn should load as the reader scrolls up.")
        let input = element("conversation-tool-call-input-\(callID)")
        XCTAssertTrue(scrollTranscriptUntilExists(input), "After a later turn, the nudged turn's call should render inline.")
        XCTAssertTrue([input.label, input.value as? String ?? ""].joined(separator: " ").contains("echo NUDGED CHECK PASSED"),
                      "The inline call should show the nudged turn's exact command.")
        // Earlier rows render only near the viewport, so each check scans the whole transcript.
        for text in visibleTexts {
            XCTAssertTrue(transcriptScan { self.transcriptContains(text) }, "A later turn keeps the nudged turn's message: \(text)")
        }
        XCTAssertTrue(transcriptScan { self.transcriptContains("ended without reporting a task outcome") }, "A later turn keeps the nudge Playhouse sent shown.")
        assertTranscriptLacks("No placeholder replaces the nudge.") { self.transcriptContains("Playhouse private outcome") }
        let later = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let texts = (later["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertTrue(texts.contains { $0.contains("ended without reporting a task outcome") }, "History after a later turn keeps the nudge shown.")
        XCTAssertFalse(texts.contains { $0.contains("private outcome") }, "No placeholder replaces the nudge.")
        for text in visibleTexts {
            XCTAssertTrue(texts.contains(text), "History after a later turn keeps: \(text)")
        }
    }
    func scheduleISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    func scheduleDate(_ text: String?) -> Date? {
        text.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    func claudeFixturePrompts() -> [String] {
        guard let executable = claudeFixtureExecutable,
              let data = FileManager.default.contents(atPath: executable + ".history"),
              let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turns = history["turns"] as? [[String: Any]] else { return [] }
        return turns.compactMap { $0["userText"] as? String }
    }
    func replaceComposerText(with text: String) {
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The task should open its composer.")
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText(text)
    }
    func closeScheduleHintAndReturnToPage() {
        let hint = element("schedule-hint")
        if hint.exists {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(waitForDisappearance(hint, timeout: 5), "Escape dismisses the schedule hint.")
        }
        element("back-to-board-button").click()
        XCTAssertTrue(waitForDisappearance(element("back-to-board-button"), timeout: 10), "Going back leaves the task conversation.")
        XCTAssertTrue(element("scheduled-tasks-empty").waitToExist(timeout: 10), "Going back returns to the empty Scheduled Tasks page.")
        XCTAssertTrue(waitForStableFrame(element("scheduled-tasks-page")), "The page should finish sliding back in.")
    }
    func openScheduleHint() -> XCUIElement {
        let button = element("schedule-task-button")
        XCTAssertTrue(waitUntil({ button.exists && button.isHittable }, timeout: 10), "The composer should offer the schedule button beside Send.")
        button.click()
        let hint = element("schedule-hint")
        XCTAssertTrue(hint.waitToExist(timeout: 5), "The schedule button should open its hint.")
        return hint
    }
    func clickScheduledTaskMenuItem(taskID: String, item identifier: String, title: String) {
        let actions = element("scheduled-task-actions-\(taskID)")
        XCTAssertTrue(actions.waitToExist(timeout: 10), "The scheduled task row should have an actions menu.")
        actions.click()
        let byIdentifier = app.menuItems.matching(identifier: identifier).firstMatch
        let item = byIdentifier.waitToExist(timeout: 3) ? byIdentifier : app.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 3), "\(title) should be in the row's menu.")
        item.click()
    }
    enum WasteFixture {
        static var logLength: String {
            var length = 0
            for index in 1...1000 {
                let time = String(format: "2026-11-03T10:%02d:%02dZ", index / 60 % 60, index % 60)
                let marker = index == 900 ? "NEEDLE-42 " : ""
                let line = "\(time) INFO fixture log line \(String(format: "%04d", index)) \(marker)request ok path=/api/orc/builds/\(String(format: "%04d", index))\n"
                length += line.unicodeScalars.count
            }
            return length.formatted(IntegerFormatStyle<Int>().grouping(.automatic))
        }
    }
    func runClaudeTokenWasteTurn(title: String) throws -> (taskID: String, environment: [String: String]) {
        var environment = try installClaudeFixture(named: "claude-fixture-ui-token-waste")
        // The CLI forwards CLAUDE_CONFIG_DIR with its requests; the window's own
        // bridge requests take the same directory from PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR.
        let claudeConfig = dataDirectory.appendingPathComponent("claude-config").path
        environment["CLAUDE_CONFIG_DIR"] = claudeConfig
        environment["PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR"] = claudeConfig
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(app.buttons[title].waitToExist(timeout: 10))
        _ = try runCLI(["conversation", "send", taskID, "--message", "Show token waste."], extraEnvironment: environment)
        return (taskID, environment)
    }
    func openTokenStats(of title: String) {
        app.buttons[title].rightClick()
        let statsAction = element("token-stats-task-menu-item")
        XCTAssertTrue(statsAction.waitToExist(timeout: 5), "The task context menu should offer Token Stats.")
        statsAction.click()
        XCTAssertTrue(element("token-stats-section-overview").waitToExist(timeout: 10), "Token Stats opens on its Overview section.")
    }
    func showTokenStatsSection(_ section: String) {
        let tab = element("token-stats-section-\(section)")
        XCTAssertTrue(tab.waitToExist(timeout: 5), "Token Stats should offer its \(section) section.")
        tab.click()
    }
    func revealRawInputRow(_ identifier: String) {
        let row = element(identifier)
        let list = element("raw-input-list")
        XCTAssertTrue(list.waitToExist(timeout: 10))
        for _ in 0..<20 where !row.exists {
            list.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(row.waitToExist(timeout: 5), "\(identifier) should be on screen after scrolling the list.")
    }
    func duplicateTokens(taskID: String, environment: [String: String]) throws -> String {
        let report = try XCTUnwrap(try runCLI(["task", "token-waste", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        let tokens = try XCTUnwrap((report["duplicates"] as? [[String: Any]])?.first?["tokensPerCopy"] as? Int)
        return tokens.formatted(IntegerFormatStyle<Int>().grouping(.automatic))
    }
    func cpuAttributionChild(executable: URL, kind: String) -> (pid: Int32, parentPID: Int32, workingDirectory: String)? {
        let record = URL(fileURLWithPath: executable.path + ".cpu-child-\(kind).json")
        guard let data = try? Data(contentsOf: record),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let parentPID = (object["parentPID"] as? NSNumber)?.int32Value,
              let workingDirectory = object["workingDirectory"] as? String else { return nil }
        return (pid, parentPID, workingDirectory)
    }
    func skillManifest(_ name: String, _ description: String, body: String = "Follow these steps.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n"
    }
    func writeSkill(in folder: URL, _ name: String, _ description: String) throws {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try skillManifest(name, description).write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    func makeSkillRepository(_ name: String, skills: [String: String], links: [String: String] = [:]) throws -> URL {
        let repository = dataDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(repository, "init", "-q", "-b", "main")
        try "# \(name)\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for (relative, text) in skills {
            let file = repository.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        for (relative, target) in links {
            let link = repository.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        try runGit(repository, "add", "-A")
        try runGit(repository, "-c", "user.name=Playhouse Test", "-c", "user.email=playhouse@example.com", "commit", "-q", "-m", "Skills fixture")
        return repository
    }
    func createSkillsTask(_ title: String, repositories: [URL], provider: String? = nil) throws -> [String: Any] {
        var command = ["task", "create", "--title", title, "--prompt", "Fixture task description."]
        if let provider { command += ["--provider", provider] }
        let taskID = try XCTUnwrap((try runCLI(command)["result"] as? [String: Any])?["id"] as? String)
        let added = try XCTUnwrap(try runCLI(["task", "repository", "add-batch", taskID] + repositories.flatMap { ["--repo", $0.path] })["result"] as? [String: Any])
        let records = try XCTUnwrap(added["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertTrue(records.allSatisfy { $0["isPending"] as? Bool == false })
        return added
    }
    func installSkillsClaudeFixture(_ name: String) throws -> URL {
        let executable = dataDirectory.appendingPathComponent(name)
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        return executable
    }
    func skillCatalog(taskID: String? = nil, includeBundled: Bool = false) throws -> [String: Any] {
        var command = ["skills", "list"]
        if let taskID { command += ["--task", taskID] }
        if includeBundled { command += ["--include-bundled", "true"] }
        return try XCTUnwrap(try runCLI(command)["result"] as? [String: Any])
    }
    func skillsByName(_ skills: Any?) -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: ((skills as? [[String: Any]]) ?? []).compactMap { skill in
            (skill["name"] as? String).map { ($0, skill) }
        })
    }
    func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    func openSkillsPage(file: StaticString = #filePath, line: UInt = #line) {
        let button = element("open-skills-button")
        XCTAssertTrue(waitUntil({ button.exists && button.isHittable }, timeout: 15), "The composer should show the Skills button.", file: file, line: line)
        button.click()
        XCTAssertTrue(element("skills-page").waitToExist(timeout: 10), "The Skills button should open the Skills page.", file: file, line: line)
        XCTAssertFalse(element("skills-loading").waitToExist(timeout: 0.5) && !waitUntil({ !self.element("skills-loading").exists }, timeout: 10),
                       "The Skills page should finish loading.", file: file, line: line)
    }
    func selectSkillsTab(_ label: String, picker identifier: String = "skills-tab-picker", file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(identifier)
        XCTAssertTrue(picker.waitToExist(timeout: 5), file: file, line: line)
        let candidates = [picker.radioButtons[label], picker.buttons[label], picker.descendants(matching: .any)[label]]
        guard let segment = candidates.first(where: { $0.exists }) else {
            XCTFail("\(identifier) has no \(label) tab.", file: file, line: line)
            return
        }
        segment.click()
    }
    func clickSkillMenuItem(skill: String, item identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let actions = element("skill-actions-\(skill)")
        XCTAssertTrue(actions.waitToExist(timeout: 10), "\(skill) should have an actions menu.", file: file, line: line)
        actions.click()
        let byIdentifier = app.menuItems.matching(identifier: identifier).firstMatch
        let item = byIdentifier.waitToExist(timeout: 3) ? byIdentifier : app.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The actions menu should offer \(title).", file: file, line: line)
        item.click()
    }
    func clickDialogButton(_ identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let byIdentifier = element(identifier)
        let button = byIdentifier.waitToExist(timeout: 3) ? byIdentifier : app.buttons[title].firstMatch
        XCTAssertTrue(button.waitToExist(timeout: 5), "The dialog should offer \(title).", file: file, line: line)
        button.click()
    }
    func isOn(_ toggle: XCUIElement) -> Bool {
        if let number = toggle.value as? NSNumber { return number.boolValue }
        return (toggle.value as? String) == "1"
    }
    func selectionCount() -> String { accessibleLabelOrValue(of: element("skills-selection-count")) }
    func boardTaskRecords() throws -> [[String: Any]] {
        try XCTUnwrap((try runCLI(["board", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]])
    }
    func privateSkillStore(_ repository: URL) -> URL {
        let digest = SHA256.hash(data: Data(repository.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return dataDirectory.appendingPathComponent("private-skills/\(repository.lastPathComponent)-\(digest)", isDirectory: true)
    }
    func writeRuleFile(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func ruleCatalog(taskID: String? = nil) throws -> [String: Any] {
        var command = ["rules", "list"]
        if let taskID { command += ["--task", taskID] }
        return try XCTUnwrap(try runCLI(command)["result"] as? [String: Any])
    }
    func rulesByID(_ catalog: [String: Any]) -> [String: [String: Any]] {
        let sections = (catalog["repositories"] as? [[String: Any]]) ?? []
        let rules = sections.flatMap { ($0["rules"] as? [[String: Any]]) ?? [] }
            + ((catalog["global"] as? [[String: Any]]) ?? []) + ((catalog["managed"] as? [[String: Any]]) ?? [])
        return Dictionary(uniqueKeysWithValues: rules.compactMap { rule in (rule["id"] as? String).map { ($0, rule) } })
    }
    func openRulesPage(file: StaticString = #filePath, line: UInt = #line) {
        openSkillsPage(file: file, line: line)
        XCTAssertEqual(accessibleLabelOrValue(of: element("skills-title")), "Skills, Rules & MCP", "The page is titled Skills, Rules & MCP.", file: file, line: line)
        selectSkillsTab("Rules", picker: "skills-kind-picker", file: file, line: line)
        XCTAssertTrue(element("rules-page").waitToExist(timeout: 10), "The Rules picker shows the rules.", file: file, line: line)
        XCTAssertTrue(waitUntil({ !self.element("rules-loading").exists }, timeout: 10), "The rules finish loading.", file: file, line: line)
    }
    func openRuleActions(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        let actions = element("rule-actions-\(key)")
        XCTAssertTrue(waitUntil({ actions.exists && actions.isHittable && !self.element("rule-editor-panel").exists && !self.element("new-rule-panel").exists }, timeout: 10),
                      "\(key) should have an actions menu.", file: file, line: line)
        actions.click()
        if !app.menuItems["Reveal in Finder"].waitToExist(timeout: 3) { actions.click() }
        XCTAssertTrue(app.menuItems["Reveal in Finder"].waitToExist(timeout: 5), "\(key)'s actions menu opens.", file: file, line: line)
    }
    func clickRuleMenuItem(rule key: String, item identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        openRuleActions(key, file: file, line: line)
        let byIdentifier = app.menuItems.matching(identifier: identifier).firstMatch
        let item = byIdentifier.waitToExist(timeout: 3) ? byIdentifier : app.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The actions menu should offer \(title).", file: file, line: line)
        item.click()
    }
    func claudeTurns(_ historyURL: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (history["turns"] as? [[String: Any]] ?? []).filter { ($0["userText"] as? String)?.isEmpty == false }
    }
    func writeMcpJSON(_ url: URL, _ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try writeRuleFile(url, String(decoding: data, as: UTF8.self) + "\n")
    }
    func readMcpJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func mcpCatalog(taskID: String? = nil) throws -> [String: Any] {
        var command = ["mcp", "list"]
        if let taskID { command += ["--task", taskID] }
        return try XCTUnwrap(try runCLI(command)["result"] as? [String: Any])
    }
    func mcpServersByID(_ catalog: [String: Any]) -> [String: [String: Any]] {
        let sections = (catalog["repositories"] as? [[String: Any]]) ?? []
        let servers = sections.flatMap { ($0["servers"] as? [[String: Any]]) ?? [] }
            + ((catalog["global"] as? [[String: Any]]) ?? []) + ((catalog["managed"] as? [[String: Any]]) ?? [])
        return Dictionary(uniqueKeysWithValues: servers.compactMap { server in (server["id"] as? String).map { ($0, server) } })
    }
    func openMcpPage(file: StaticString = #filePath, line: UInt = #line) {
        openSkillsPage(file: file, line: line)
        XCTAssertEqual(accessibleLabelOrValue(of: element("skills-title")), "Skills, Rules & MCP", "The page is titled Skills, Rules & MCP.", file: file, line: line)
        selectSkillsTab("MCP", picker: "skills-kind-picker", file: file, line: line)
        XCTAssertTrue(element("mcp-page").waitToExist(timeout: 10), "The MCP picker shows the servers.", file: file, line: line)
        XCTAssertTrue(waitUntil({ !self.element("mcp-loading").exists }, timeout: 10), "The servers finish loading.", file: file, line: line)
    }
    func clickMcpMenuItem(server key: String, item identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let actions = element("mcp-actions-\(key)")
        XCTAssertTrue(waitUntil({ actions.exists && actions.isHittable && !self.element("mcp-editor-panel").exists }, timeout: 10),
                      "\(key) should have an actions menu.", file: file, line: line)
        actions.click()
        let byIdentifier = app.menuItems.matching(identifier: identifier).firstMatch
        if !byIdentifier.waitToExist(timeout: 3), !app.menuItems[title].exists { actions.click() }
        let item = byIdentifier.waitToExist(timeout: 3) ? byIdentifier : app.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The actions menu should offer \(title).", file: file, line: line)
        item.click()
    }
    func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        if !text.isEmpty { field.typeText(text) }
    }
    func useLiveProvider(taskID: String) throws {
        guard let liveProvider else { return }
        let switched = try XCTUnwrap(try runCLI(["conversation", "provider", taskID, "set", liveProvider])["result"] as? [String: Any])
        XCTAssertEqual(switched["conversationProvider"] as? String, liveProvider)
    }
    func assertPluginValuesCrossWithJSONRules() throws {
        func node(_ testID: String, in tree: Any?) -> [String: Any]? {
            guard let object = tree as? [String: Any] else { return nil }
            if (object["props"] as? [String: Any])?["testID"] as? String == testID { return object }
            for child in object["children"] as? [Any] ?? [] {
                if let found = node(testID, in: child) { return found }
            }
            return nil
        }
        func text(_ node: [String: Any]?) -> String {
            (node?["children"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        let source = """
        function App() {
          var picked = React.useState("none");
          return h(Stack, { testID: "values" },
            h(Text, { testID: "props-echo" }, JSON.stringify(Playhouse.props)),
            h(Text, { testID: "nan", size: NaN, label: new Date(0) }, "x"),
            h(PillPicker, { testID: "pill", selected: "a", onChange: function (value) { picked[1](typeof value + " " + value); },
              options: [{ value: "a", label: "A", help: undefined, extra: function () {}, gone: { toJSON: function () { return undefined; } }, selfish: { toJSON: function () { return this; } } }, inherits] }),
            h(Text, { testID: "picked" }, picked[0]));
        }
        var inherits = Object.create({ inherited: "x" });
        inherits.value = "b";
        inherits.label = "B";
        Playhouse.render(h(App));
        """
        let file = dataDirectory.appendingPathComponent("plugin-values.js")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let props = #"{"nested":{"list":[1,2.5,"two",true,null],"flag":false},"title":"Hi"}"#
        let values = try XCTUnwrap(try runCLI(["plugin", "render", "--file", file.path, "--props", props, "--event", "pill:onChange:b"])["result"] as? [String: Any])
        XCTAssertEqual(values["errors"] as? [String], [])
        let tree = values["tree"]
        let echoed = try JSONSerialization.jsonObject(with: Data(text(node("props-echo", in: tree)).utf8)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(props.utf8)) as? NSDictionary
        XCTAssertEqual(echoed, expected, "The plugin's props reach JavaScript with their types and nesting intact.")
        let nan = try XCTUnwrap(node("nan", in: tree)?["props"] as? [String: Any])
        XCTAssertTrue(nan["size"] is NSNull, "NaN crosses as null, as JSON.stringify sends it.")
        XCTAssertEqual(nan["label"] as? String, "1970-01-01T00:00:00.000Z", "A Date crosses as its toJSON() string.")
        let pill = try XCTUnwrap(node("pill", in: tree)?["props"] as? [String: Any])
        XCTAssertEqual(pill["options"] as? NSArray, [["value": "a", "label": "A", "selfish": [String: String]()], ["value": "b", "label": "B"]] as NSArray,
                       "Undefined, function, undefined-toJSON and inherited fields are left out of nested values, and toJSON runs once (a self-returning one gives {}).")
        XCTAssertEqual(pill["selected"] as? String, "a")
        XCTAssertEqual(text(node("picked", in: tree)), "string b", "An event value arrives as a JavaScript string.")

        let circularFile = dataDirectory.appendingPathComponent("plugin-circular.js")
        try #"var loop = {}; loop.self = loop; Playhouse.render(h(PillPicker, { selected: "a", options: [{ value: "a", label: "A", extra: loop }] }));"#
            .write(to: circularFile, atomically: true, encoding: .utf8)
        let circular = try XCTUnwrap(try runCLI(["plugin", "render", "--file", circularFile.path], expectedStatus: 1)["result"] as? [String: Any])
        XCTAssertTrue((circular["errors"] as? [String] ?? []).contains { $0.contains("circular") }, "A circular prop is reported: \(circular)")

        let outOfRangeFile = dataDirectory.appendingPathComponent("plugin-out-of-range.js")
        try #"__native.commit([{ op: "createText", id: 1e300, text: "x" }]);"#.write(to: outOfRangeFile, atomically: true, encoding: .utf8)
        let outOfRange = try XCTUnwrap(try runCLI(["plugin", "render", "--file", outOfRangeFile.path], expectedStatus: 1)["result"] as? [String: Any])
        XCTAssertTrue((outOfRange["errors"] as? [String] ?? []).contains { $0.contains("Invalid commit") && $0.contains("integer") },
                      "An op whose node id is out of range is reported, not a crash: \(outOfRange)")

        // Atom props decode straight from the values; an invalid one names its path and what is wrong.
        for (index, (source, message)) in [
            (#"Playhouse.render(h(Text, { size: "large" }, "x"));"#, "<Text> has an invalid prop: size: expected a number, found a string"),
            (#"Playhouse.render(h(Text, { lineLimit: 1.5 }, "x"));"#, "<Text> has an invalid prop: lineLimit: expected a whole number, found 1.5"),
            (#"Playhouse.render(h(Label, { icon: "clock" }));"#, "<Label> has an invalid prop: text: missing"),
            (#"Playhouse.render(h(PillPicker, { selected: "a", options: [{ value: "a" }] }));"#, "<PillPicker> has an invalid prop: options.0.label: missing"),
        ].enumerated() {
            let invalidFile = dataDirectory.appendingPathComponent("plugin-invalid-\(index).js")
            try source.write(to: invalidFile, atomically: true, encoding: .utf8)
            let invalid = try XCTUnwrap(try runCLI(["plugin", "render", "--file", invalidFile.path], expectedStatus: 1)["result"] as? [String: Any])
            XCTAssertTrue((invalid["errors"] as? [String] ?? []).contains { $0.contains(message) }, "\(source) reports \(message): \(invalid)")
        }
    }
    func writeInstalledPlugin(_ id: String, source: String?, placement: String = "composerActions", presentation: String = "popover", name: String? = nil, icon: String = "puzzlepiece.extension") throws {
        let folder = pluginsFolder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["id": id, "name": name ?? id.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
                                       "icon": icon, "placement": placement, "presentation": presentation]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
        if let source { try source.write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8) }
    }
    func pluginMode() throws -> Bool {
        try XCTUnwrap((try runCLI(["plugin", "mode"])["result"] as? [String: Any])?["enabled"] as? Bool)
    }
    func installedPluginIDs() throws -> [String] {
        let plugins = try XCTUnwrap((try runCLI(["plugin", "list"])["result"] as? [String: Any])?["plugins"] as? [[String: Any]])
        return plugins.compactMap { $0["id"] as? String }
    }
    func startPluginFetchServer() throws -> (base: String, closed: String) {
        let server = try PluginFetchServer()
        addTeardownBlock { withExtendedLifetime(server) {} }
        return ("http://127.0.0.1:\(server.port)", "http://127.0.0.1:\(try PluginFetchServer.closedPort())")
    }
    func clickDebugHighlightNativeAtoms() {
        let menu = app.menuBars.menuBarItems["Debug"]
        XCTAssertTrue(menu.waitToExist(timeout: 10), "The app menu has a Debug menu.")
        menu.click()
        let item = menu.menuItems["Highlight Native Atoms"]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The Debug menu has Highlight Native Atoms.")
        item.click()
    }
    func catalogSidebarRow(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = element(identifier)
        let sidebar = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH %@", "plugin-catalog-atom-")).firstMatch
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "The Plugin Catalog shows its sidebar.", file: file, line: line)
        // One check per scroll: up first, then down past where it started.
        var scrolls = 0
        while !(row.exists && row.isHittable), scrolls < 20 {
            sidebar.scroll(byDeltaX: 0, deltaY: scrolls < 10 ? 200 : -200)
            scrolls += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(identifier) should be on screen after scrolling the catalog sidebar.", file: file, line: line)
        return row
    }
    func clickPluginsMenuItem(_ title: String) {
        let menu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(menu.waitToExist(timeout: 10), "The app menu has a Plugins menu.")
        menu.click()
        // Scoped to the Plugins menu: the Window menu also lists the catalog window by title.
        let item = menu.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The Plugins menu has \(title).")
        item.click()
    }
    func pluginText(_ element: XCUIElement) -> String {
        let value = element.value as? String ?? ""
        return value.isEmpty ? element.label : value
    }
    func launchApp(defaultParent: String?, environmentOverrides: [String: String] = [:]) {
        clearSavedWindowFrames()
        launchDefaultParent = defaultParent
        let bundleIdentifier = Bundle(url: appBundle)?.bundleIdentifier ?? "com.playhouse.app.e2e"
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        app.launchEnvironment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        app.launchEnvironment["CODEX_HOME"] = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        app.launchEnvironment["PLAYHOUSE_WORKTREE_LABEL"] = "Playhouse UI Test Worktree"
        app.launchEnvironment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["PLAYHOUSE_E2E_DEFAULT_PARENT_FOLDER"] = defaultParent ?? "__unset__"
        if let launchWindowTitle {
            app.launchEnvironment["PLAYHOUSE_WINDOW_TITLE"] = launchWindowTitle
        }
        app.launchEnvironment.merge(providerExecutableEnvironment, uniquingKeysWith: { _, new in new })
        if let codexFixtureStateDirectory {
            app.launchEnvironment["PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY"] = codexFixtureStateDirectory.path
        }
        for (key, value) in environmentOverrides {
            app.launchEnvironment[key] = value
        }
        launchAppWithOpen(bundleIdentifier: bundleIdentifier, environmentOverrides: environmentOverrides)
        waitForBoardOrAbortSuite()
        let newTaskButton = element("new-task-button")
        if newTaskButton.exists && !newTaskButton.isHittable {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            windowMenu.click()
            let zoom = app.menuItems["Zoom"]
            if zoom.waitToExist(timeout: 2) {
                zoom.click()
            } else {
                app.typeKey("z", modifierFlags: [.command, .option])
            }
            app.activate()
        }
    }
    func launchAppWithOpen(bundleIdentifier: String? = nil, environmentOverrides: [String: String] = [:]) {
        let targetBundleIdentifier = bundleIdentifier ?? Bundle(url: appBundle)?.bundleIdentifier ?? "com.playhouse.app.e2e"
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let codexHome = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        environment["CODEX_HOME"] = codexHome
        environment["PLAYHOUSE_WORKTREE_LABEL"] = "Playhouse UI Test Worktree"
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_E2E_DEFAULT_PARENT_FOLDER"] = launchDefaultParent ?? "__unset__"
        if usesLiveCodex {
            environment["PLAYHOUSE_RUN_CODEX_INTEGRATION"] = "1"
        }
        if let launchWindowTitle {
            environment["PLAYHOUSE_WINDOW_TITLE"] = launchWindowTitle
        }
        environment.merge(providerExecutableEnvironment, uniquingKeysWith: { _, new in new })
        if let codexFixtureStateDirectory {
            environment["PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY"] = codexFixtureStateDirectory.path
        }
        environment.merge(environmentOverrides, uniquingKeysWith: { _, new in new })
        app = XCUIApplication(bundleIdentifier: targetBundleIdentifier)
        app.launchEnvironment = environment
        // Every case starts from no restored windows. AppKit saves open windows on
        // quit and reopens them on the next launch; a plugin window left open by
        // an earlier case (or session) reopens against this case's data directory,
        // shows "has no plugin.json", and covers the board.
        // The sandboxed test runner's `clearSavedWindowFrames` reaches only its own container, so
        // the main window's saved frame in the app's defaults survives between cases and an earlier
        // case's window size leaks into the next. An empty frame in the launch-argument domain,
        // which takes precedence, makes every case open the main window at its default size.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSWindow Frame main", ""]
        app.launch()
    }
}

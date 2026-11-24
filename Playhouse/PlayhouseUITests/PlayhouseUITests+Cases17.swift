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
    // case-contract: test_codex_agent_image_published_during_active_turn | While a Codex turn is active, CLI/XPC image publication avoids requesting provider history; the assistant image is tied to that turn, is recorded in Playhouse's store when published, so it follows the turn's prompt and precedes the answer that arrives later and the next turn in ordered history, as for Claude, and remains visible after reopening the conversation.
    func test_codex_agent_image_published_during_active_turn() throws {
        let source = WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        let executable = dataDirectory.appendingPathComponent("codex-fixture-image-serial-success-wait")
        try copyFixtureFile(at: source, to: executable)
        codexFixtureExecutable = executable.path
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let ready = URL(fileURLWithPath: executable.path + ".resolve-ready")
        let release = URL(fileURLWithPath: executable.path + ".resolve-continue")
        let observeHistory = URL(fileURLWithPath: executable.path + ".observe-history-while-active")
        let historyRead = URL(fileURLWithPath: executable.path + ".history-read-while-active")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: release)
        try? FileManager.default.removeItem(at: observeHistory)
        try? FileManager.default.removeItem(at: historyRead)
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Codex active image", roots: [fixture.primary.path])
        openTask(named: "Codex active image")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Please publish-image-during-active-turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "Codex should hold the active turn before its native response.")

        let image = dataDirectory.appendingPathComponent("active-codex-agent-image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        try Data().write(to: observeHistory)
        let published = try runCLI([
            "conversation", "present-image", try taskID(named: "Codex active image"), "--image", image.path, "--caption", "Generated while Codex was responding",
        ])["result"] as? [String: Any]
        let imageID = try XCTUnwrap(published?["id"] as? String)
        let publishedTurnID = try XCTUnwrap(published?["turnID"] as? String)
        XCTAssertFalse(publishedTurnID.isEmpty, "The published image should carry the active Codex turn ID.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyRead.path), "Publishing during a Codex turn must not request its busy provider history.")
        try FileManager.default.removeItem(at: observeHistory)
        try Data("Release Codex's turn.\n".utf8).write(to: release)
        XCTAssertTrue(element("chat-image-\(imageID)-0").waitToExist(timeout: 20), "The image returned during the active turn should render in the transcript.")

        let followupText = "Start a later turn after the generated image."
        composer.click()
        composer.typeText(followupText)
        element("send-message-button").click()
        let visibleImage = element("chat-image-\(imageID)-0")
        let visibleFollowup = transcriptMessage(followupText)
        XCTAssertTrue(visibleFollowup.waitToExist(timeout: 10), "The later user turn should be visible in the transcript.")
        XCTAssertLessThan(visibleImage.frame.minY, visibleFollowup.frame.minY, "The rendered generated image should appear before the later user turn.")

        let history = try runCLI(["conversation", "history", try taskID(named: "Codex active image")])["result"] as? [String: Any]
        let messages = try XCTUnwrap(history?["messages"] as? [[String: Any]])
        let imageIndex = try XCTUnwrap(messages.firstIndex { $0["id"] as? String == imageID })
        let answerIndex = try XCTUnwrap(messages.firstIndex { $0["text"] as? String == "Answers received: Blue / fixture-secret." })
        let followupIndex = try XCTUnwrap(messages.firstIndex { $0["role"] as? String == "user" && $0["text"] as? String == followupText })
        let promptIndex = try XCTUnwrap(messages.firstIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Please publish-image-during-active-turn." })
        XCTAssertGreaterThan(imageIndex, promptIndex, "The image should follow the prompt of the turn it was published in.")
        XCTAssertLessThan(imageIndex, answerIndex, "Playhouse records the image when it is published, before the answer that arrives later.")
        XCTAssertEqual(publishedTurnID, messages[answerIndex]["turnID"] as? String, "The published image should share the active Codex response's turn ID.")
        XCTAssertEqual(messages[imageIndex]["turnID"] as? String, publishedTurnID, "History should preserve the published image's turn ID.")
        XCTAssertLessThan(imageIndex, followupIndex, "The image should remain before the next Codex turn.")
        element("back-to-board-button").click()
        openTask(named: "Codex active image")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        XCTAssertTrue(element("chat-image-\(imageID)-0").waitToExist(timeout: 10), "Reopening the Codex conversation should render the exact published image.")
    }
    // case-contract: test_claude_turn_progress_reaches_other_windows_mid_turn | While a Claude Code fixture turn started by another caller is still running, its commentary and tool activity raise the task's conversation revision in the daemon's runtime snapshot, a held turn with no visible output yet leaves that revision unchanged, and mid-turn history, read from Playhouse's own Claude transcript, already returns the prompt, the commentary, and the in-progress tool activity before any final answer. A conversation reopened after its send, and so no longer reading that turn's stream, shows the commentary and the running tool row while the turn is still held, then the final answer once it settles; the revision rises again when the turn ends.
    func test_claude_turn_progress_reaches_other_windows_mid_turn() throws {
        try assertTurnProgressReachesReopenedConversation(
            provider: "claude", fixtureSource: "claude-fixture-ui",
            executableName: "claude-fixture-follow-active-turn", activityID: "toolu_follow_active_step"
        )
    }
    // case-contract: test_codex_turn_progress_reaches_other_windows_mid_turn | While a Codex app-server fixture turn started by another caller is still running, its commentary and tool activity raise the task's conversation revision in the daemon's runtime snapshot, a held turn with no visible output yet leaves that revision unchanged, and mid-turn history, read from Playhouse's own transcript store while the turn holds, already returns the prompt, the commentary, and the in-progress tool activity before any final answer. A conversation reopened after its send, and so no longer reading that turn's stream, shows the commentary and the running tool row while the turn is still held, then the final answer once it settles; the revision rises again when the turn ends. With a non-default model selected, those mid-turn history reads never send thread/resume, since history comes from Playhouse's store.
    func test_codex_turn_progress_reaches_other_windows_mid_turn() throws {
        try assertTurnProgressReachesReopenedConversation(
            provider: "codex", fixtureSource: "codex-fixture-ui",
            executableName: "codex-fixture-follow-active-turn", activityID: "item_follow_active_command", modelID: "gpt-6-sol"
        )
    }
    // case-contract: test_conversation_follows_latest_streamed_messages | While a Claude Code fixture reply streams in held stages below its question, mid-turn CLI/XPC history holds every streamed line before the newest, which Claude may still extend as its answer, once each and in order after the question, with no final line until the reply is released, and the settled turn ends with its final line after every streamed line. In the visible transcript, a reader at the bottom follows the reply: once it outgrows the viewport, the newest streamed line stays in view and the question scrolls away. Scrolling up stops following, so the next stage leaves the reader's position unchanged and its lines out of view; scrolling back to the bottom resumes following, so the next stage's newest line is in view while the turn is still running; reopening the conversation while that turn is still running opens it at that newest line instead of at the question and keeps following, so the next stage's newest line is in view while the turn is still running and the settled turn leaves its final line in view. A short follow-up with a tool call then becomes the newest turn, and the newest history page ends with its question, tool call, and answer after the streamed turn. Scrolled as far down as it goes, the transcript has no blank overscroll: while the held reply outgrows the viewport it ends at its newest line, and the settled reply, whose streamed lines fold into Worked for, and the short follow-up, both once it settles and after the settled conversation is reopened, keep the newest question pinned near the top. Following is shared transcript presentation, so one representative provider covers it.
    func test_conversation_follows_latest_streamed_messages() throws {
        let executable = try installClaudeFixtureExecutable(named: "claude-fixture-stream-follow")
        func ready(_ stage: Int) -> URL { URL(fileURLWithPath: executable.path + ".stream-follow-ready-\(stage)") }
        func release(_ stage: Int) throws {
            try Data("Continue.\n".utf8).write(to: URL(fileURLWithPath: executable.path + ".stream-follow-release-\(stage)"))
        }
        defer {
            for stage in 1...5 where FileManager.default.fileExists(atPath: ready(stage).path) { try? release(stage) }
        }
        let title = "Streamed follow turn"
        let prompt = "Please stream-follow-latest."
        func line(_ number: Int) -> XCUIElement {
            let text = String(format: "Streamed follow line %02d:", number)
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", text))
                .firstMatch
        }

        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude"])
        let finalLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Streamed follow reply finished."))
            .firstMatch
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        let scrollView = element("conversation-scroll-view")
        // The opening history load re-pins the newest turn when it lands; sending first lets that
        // pin land after the reply outgrew the viewport, which is not "at the bottom".
        XCTAssertTrue(waitUntil({ scrollView.exists && scrollView.value as? String != "Loading conversation history" }, timeout: 15),
                      "The conversation should finish loading before the message is sent.")
        composer.click()
        composer.typeText(prompt)
        element("send-message-button").click()
        // A row far from the viewport stops rendering as the transcript scrolls, so one that
        // exists can be gone by the time its frame is read; a snapshot reads it without failing.
        func frame(_ candidate: XCUIElement) -> CGRect? {
            candidate.exists ? (try? candidate.snapshot())?.frame : nil
        }
        func isInView(_ candidate: XCUIElement) -> Bool {
            frame(candidate).map { scrollView.frame.insetBy(dx: 0, dy: -2).contains($0) } ?? false
        }
        func isOutOfView(_ candidate: XCUIElement) -> Bool {
            frame(candidate).map { !scrollView.frame.intersects($0) } ?? true
        }

        // At the bottom when the reply starts, the transcript follows it past its question.
        // Claude's newest text is shown once something follows it, so each held
        // stage shows every line but its last.
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready(1).path) }, timeout: 20), "The fixture should hold the first streamed stage.")
        XCTAssertTrue(line(19).waitToExist(timeout: 10), "The first stage's lines should stream into the transcript.")
        XCTAssertTrue(waitUntil({ isInView(line(19)) }, timeout: 5), "Following the bottom should keep the newest streamed line in view; line=\(line(19).frame), viewport=\(scrollView.frame).")
        let question = transcriptMessage(prompt)
        XCTAssertTrue(isOutOfView(question), "A reply taller than the viewport should carry the question out of view while following; question=\(question.frame), viewport=\(scrollView.frame).")
        attachScreenshot(named: "Following the newest streamed line")

        try release(1)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready(2).path) }, timeout: 20), "The fixture should hold the second streamed stage.")
        XCTAssertTrue(line(27).waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ isInView(line(27)) }, timeout: 5), "Following should continue as later lines arrive; line=\(line(27).frame), viewport=\(scrollView.frame).")

        // Scrolling up stops following: the next stage leaves the reader where they were.
        for _ in 0..<10 {
            guard !isOutOfView(line(27)) else { break }
            scrollView.scroll(byDeltaX: 0, deltaY: 200)
        }
        XCTAssertTrue(isOutOfView(line(27)), "Scrolling up should move the newest line out of view.")
        // The lowest line still in view marks the reader's position; record it once the wheel settles.
        var readingFrame = CGRect.null
        _ = waitUntil({
            let frame = (1...26).reversed().map(line).first(where: isInView)?.frame ?? .null
            defer { readingFrame = frame }
            return frame == readingFrame
        }, timeout: 3)
        let readingLine = try XCTUnwrap((1...26).reversed().map(line).first(where: isInView), "Scrolling up should leave earlier lines in view to read.")
        readingFrame = readingLine.frame
        try release(2)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready(3).path) }, timeout: 20), "The fixture should hold the third streamed stage.")
        XCTAssertTrue(line(35).waitToExist(timeout: 10), "The third stage's lines should still stream in.")
        // Give a wrongly resumed follow time to move the viewport before judging it.
        _ = waitUntil({ !isOutOfView(line(35)) }, timeout: 2)
        XCTAssertTrue(isOutOfView(line(35)), "After scrolling up, new lines should arrive below without pulling the reader down; line=\(line(35).frame), viewport=\(scrollView.frame).")
        XCTAssertLessThanOrEqual(abs(readingLine.frame.minY - readingFrame.minY), 4, "The line being read should stay where it was while new lines arrive below; before=\(readingFrame), after=\(readingLine.frame).")
        attachScreenshot(named: "Scrolled up while the reply keeps streaming")

        // Scrolling back to the bottom resumes following.
        for _ in 0..<30 {
            guard !isInView(line(35)) else { break }
            scrollView.scroll(byDeltaX: 0, deltaY: -300)
        }
        for _ in 0..<3 { scrollView.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(isInView(line(35)), "Scrolling down should reach the newest line.")
        try release(3)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready(4).path) }, timeout: 20), "The fixture should hold the fourth streamed stage.")
        XCTAssertTrue(line(43).waitToExist(timeout: 10), "The fourth stage's lines should stream in.")
        XCTAssertTrue(waitUntil({ isInView(line(43)) }, timeout: 5), "Back at the bottom, following should resume and keep the newest line in view while the turn runs; line=\(line(43).frame), viewport=\(scrollView.frame).")
        attachScreenshot(named: "Following resumed at the bottom")
        // The held reply is far taller than the viewport, so its bottom is its newest line.
        assertTranscriptEndsWithoutOverscroll(question: question, lastRow: line(43), in: scrollView, turnFitsViewport: false)
        // A conversation reopened while its turn is still running opens at the newest line, not
        // at the turn's question, and follows the reply from there.
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10), "The running conversation should return to the board before reopening.")
        openTask(named: title)
        XCTAssertTrue(waitUntil({ isInView(line(43)) }, timeout: 15), "A conversation reopened mid-turn should open at its newest line; line=\(line(43).frame), viewport=\(scrollView.frame).")
        XCTAssertTrue(isOutOfView(question), "A conversation reopened mid-turn should open at the end of the reply, past its question; question=\(question.frame), viewport=\(scrollView.frame).")
        attachScreenshot(named: "Reopened running conversation opens at its newest line")
        // Nothing scrolls from here on: only following keeps the next stage's lines in view.
        try release(4)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready(5).path) }, timeout: 20), "The fixture should hold the fifth streamed stage.")
        XCTAssertTrue(line(51).waitToExist(timeout: 10), "The fifth stage's lines should stream into the reopened conversation.")
        XCTAssertTrue(waitUntil({ isInView(line(51)) }, timeout: 5), "A conversation reopened mid-turn should keep following the reply while it runs; line=\(line(51).frame), viewport=\(scrollView.frame).")
        XCTAssertTrue(isOutOfView(line(35)), "Following the reopened reply should carry its earlier lines out of view; line=\(line(35).frame), viewport=\(scrollView.frame).")
        attachScreenshot(named: "Reopened running conversation keeps following")
        try release(5)
        XCTAssertTrue(finalLine.waitToExist(timeout: 30), "The final line should arrive once the reply is released.")
        XCTAssertTrue(waitUntil({ isInView(finalLine) }, timeout: 10), "The settled turn should leave its final line in view; line=\(finalLine.frame), viewport=\(scrollView.frame).")
        // Settling folds the streamed lines into Worked for, so the settled turn fits the
        // viewport again and its question returns to the top.
        assertTranscriptEndsWithoutOverscroll(question: question, lastRow: try latestMessageRow(titled: title), in: scrollView, turnFitsViewport: false)
        attachScreenshot(named: "Scrolled to the bottom of the settled reply")

        // A follow-up whose turn fits the viewport is pinned to the top, and the space below it
        // is sized from the turn as it settles, tool row and answer included, not from the
        // question alone at the moment it was sent.
        let followUp = "Summarize the release notes."
        let closing = app.groups.matching(NSPredicate(format: "label CONTAINS %@", "Tell me if you want the upgrade command.")).firstMatch
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText(followUp)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.fixtureTurnCount(executable, containing: followUp) > 0 && self.noTurnIsRunning() }, timeout: 30),
                      "The follow-up turn should finish.")
        XCTAssertTrue(closing.waitToExist(timeout: 10), "The follow-up's answer should render.")
        assertTranscriptEndsWithoutOverscroll(question: transcriptMessage(followUp), lastRow: try latestMessageRow(titled: title), in: scrollView, turnFitsViewport: false)
        attachScreenshot(named: "Scrolled to the bottom after a short follow-up")

        // Reopening the settled conversation is a fresh view that opens on the newest turn, with
        // the earlier one held back above it; scrolling straight down must reach the same end.
        element("back-to-board-button").click()
        openTask(named: title)
        XCTAssertTrue(closing.waitToExist(timeout: 10), "The reopened conversation should show the newest answer.")
        assertTranscriptEndsWithoutOverscroll(question: transcriptMessage(followUp), lastRow: try latestMessageRow(titled: title), in: scrollView, turnFitsViewport: false)
        attachScreenshot(named: "Reopened conversation scrolled to the bottom")
    }
    // case-contract: test_claude_earlier_turn_tool_calls_render_inline | A Claude Code fixture turn that writes commentary, runs shell commands (one failing) and an MCP call, then answers keeps each call in Playhouse's own transcript placed after the message written before it. Once a later turn starts, CLI/XPC history still returns the earlier turn's calls as timeline activities, apart from the latest turn's activities: each shell call carries its stated purpose, its exact command and the output it returned, the failing call reports failed, and the MCP call exposes neither its arguments nor its raw result. A history page returns only the calls placed on its own messages, so the newest page carries none of them and the page before it carries them all. While its turn is the latest, a call stays in Worked for and is not shown inline. Once a later turn starts, the visible conversation shows each earlier call inline between those messages, in order, each shell call as one line with the tool's name and the start of its command, a command longer than the row or spanning several lines cut to its first line with an ellipsis, which expands to its purpose and full IN and OUT blocks; the MCP row has no IN or OUT block, the turn's answer renders a numbered list written right under a paragraph line as separate items whose inline code text is unchanged, and the rows are still there after reopening the task.
    func test_claude_earlier_turn_tool_calls_render_inline() throws {
        try assertEarlierTurnToolCallsRenderInline(
            provider: "claude", executableName: "claude-fixture-timeline-tools",
            callIDs: ["toolu_timeline_status", "toolu_timeline_list", "toolu_timeline_fail", "toolu_timeline_mcp"],
            summaries: ["Check repository status", "List fixture files"]
        )
    }
    // case-contract: test_codex_earlier_turn_tool_calls_render_inline | A Codex app-server fixture thread whose earlier turn reports commentary, command executions (one failing) and an MCP call between its messages keeps those items in their place in history: once a later turn starts, CLI/XPC history returns each earlier call as a timeline activity placed after the message the thread listed before it, with its working directory, exact command and aggregated output, the failing command reports failed, and the MCP call exposes neither its arguments nor its raw result. Commentary on either side of a call stays a separate message instead of merging across it. A history page returns only the calls placed on its own messages, so the newest page carries none of them and the page before it carries them all. While its turn is the latest, a call stays in Worked for and is not shown inline. Once a later turn starts, the visible conversation shows each earlier call inline between those messages, in order, each shell call as one line with the tool's name and the start of its command, a command longer than the row or spanning several lines cut to its first line with an ellipsis, which expands to its working directory and full IN and OUT blocks; the MCP row has no IN or OUT block, the turn's answer renders a numbered list written right under a paragraph line as separate items whose inline code text is unchanged, and the rows are still there after reopening the task.
    func test_codex_earlier_turn_tool_calls_render_inline() throws {
        try assertEarlierTurnToolCallsRenderInline(
            provider: "codex", executableName: "codex-fixture-unique-turns-timeline-tool-calls",
            callIDs: ["item_timeline_status", "item_timeline_list", "item_timeline_fail", "item_timeline_mcp"],
            summaries: ["in /tmp/playhouse-fixture", "in /tmp/playhouse-fixture"]
        )
    }
    // case-contract: test_conversation_rejects_invalid_image_attachments | Malformed image data is rejected with a visible composer error and an invalid_argument bridge response, without creating conversation history or advancing task status.
    func test_conversation_rejects_invalid_image_attachments() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Invalid image conversation", roots: [fixture.primary.path])
        openTask(named: "Invalid image conversation")
        let invalid = dataDirectory.appendingPathComponent("invalid-chat-image.png")
        try Data("not an image".utf8).write(to: invalid)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try Data(contentsOf: invalid), forType: .png)
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 5), "Pasting malformed image bytes should show a visible validation error.")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("valid images"))
        XCTAssertTrue(element("send-message-button").isEnabled == false, "An invalid image must not enable send.")

        let taskID = try taskID(named: "Invalid image conversation")
        let bridgeResult = try runCLI(["conversation", "send", taskID, "--image", invalid.path], expectedStatus: 2)
        XCTAssertEqual((bridgeResult["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Backlog")
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
    }
    // case-contract: test_conversation_shows_mcp_and_dynamic_tool_activity | MCP and dynamic tool lifecycle updates coalesce by stable item ID into distinct visible conversation rows; each call reports its start and measured duration, and completed durations persist through history reload. While a tool call holds the sent turn active, the transcript never shows blank space: the submitted user message is in view, or, once the turn's activity has outgrown the viewport and the transcript follows it, the message sits above the latest live activity, which is in view. The latest active process, including a long command, appears outside Working for on one truncated line; older active processes remain inside, and completion moves it inside. The conversation header has no live activity line while responding. Working for renders open while the turn runs, so its progress is visible without a click and lists the in-flight calls instead of a Thinking row, and it is still open after leaving and reopening the task mid-turn; every in-flight call is readable from mid-turn history. A collapse the reader performs mid-turn is honored and survives the activity updates that follow, and the final answer closes the section back into a clean collapsed Worked for. The expanded Working for list shows each call's live or completed duration. In-progress, completed, and failed statuses, server/tool identity, and safe result summaries render without duplicate rows in the live turn and in history reloaded from Playhouse's store. Arguments and raw result text are never exposed.
    func test_conversation_shows_mcp_and_dynamic_tool_activity() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-tool-activity").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(codexFixtureExecutable)))
        launchApp(defaultParent: fixture.primary.path)
        _ = try runCLI(["task", "create", "--title", "Tool activity", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Tool activity")
        openTask(named: "Tool activity")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Show tool activity.")
        element("send-message-button").click()

        let fixture = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable))
        let toolReady = URL(fileURLWithPath: fixture.path + ".tool-ready")
        let toolReleaseLatest = URL(fileURLWithPath: fixture.path + ".tool-release-latest")
        let toolRelease = URL(fileURLWithPath: fixture.path + ".tool-release")
        defer {
            try? "Release newest tool after assertion failure.\n".write(to: toolReleaseLatest, atomically: true, encoding: .utf8)
            try? "Release tool completions after assertion failure.\n".write(to: toolRelease, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: toolReady.path) }, timeout: 20), "The fixture should pause after the tool start notifications.")
        XCTAssertFalse(element("current-activity-indicator").exists, "The conversation header should not show a live activity line while responding.")
        let latestActiveRow = element("codex-activity-row-item_fixture_active_long_command")
        XCTAssertTrue(latestActiveRow.waitToExist(timeout: 10), "The latest active process should appear outside Working for.")
        // The open Working for list can outgrow the viewport, and then the transcript follows
        // the live activity. Either way the viewport must show the turn, never blank space.
        let sentMessage = transcriptMessage("Show tool activity.")
        let transcriptViewport = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            let viewport = transcriptViewport.frame
            let message = sentMessage.frame
            let latest = latestActiveRow.frame
            guard sentMessage.exists else { return false }
            if viewport.contains(message) { return true }
            return message.maxY <= latest.minY && viewport.contains(latest)
        }, timeout: 5), "While the sent turn is still held active, the transcript must show the submitted message, or the latest live activity below it, instead of blank space.")
        XCTAssertLessThan(latestActiveRow.frame.height, 45, "The long active command should remain a single truncated line.")
        let activityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Expanded, down chevron" }, timeout: 10),
                      "A turn in flight should show its work instead of hiding it behind Working for.")
        let activityDetails = element("codex-activity-details")
        XCTAssertTrue(activityDetails.waitToExist(timeout: 5), "Working for should already list this turn's tool activity.")
        XCTAssertTrue(element("codex-activity-row-item_fixture_mcp_call").waitToExist(timeout: 10), "Working for should list an in-flight call.")
        XCTAssertFalse(element("codex-activity-thinking").exists, "Thinking should give way once Working for lists activity.")
        attachScreenshot(named: "Working for stays open while the turn runs")
        // Activity rows are groups; their details and durations are child texts.
        func rowText(_ id: String) -> String {
            [element("codex-activity-row-\(id)").label,
             element("codex-activity-detail-\(id)").value as? String ?? "",
             element("codex-activity-duration-\(id)").value as? String ?? ""].joined(separator: " ")
        }
        func containsPositiveDuration(_ value: String) -> Bool {
            value.range(of: #"Duration · [1-9][0-9]* ms"#, options: .regularExpression) != nil
        }
        func containsPositiveRunningDuration(_ value: String) -> Bool {
            value.range(of: #"Running · [1-9][0-9]* ms"#, options: .regularExpression) != nil
        }
        let mcpRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").firstMatch
        let dynamicRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").firstMatch
        let legacyDynamicRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").firstMatch
        let commandRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_active_long_command").firstMatch
        XCTAssertTrue(mcpRow.waitToExist(timeout: 10), "Older MCP calls should remain inside expanded Working for.")
        XCTAssertTrue(dynamicRow.waitToExist(timeout: 10), "Older dynamic calls should remain inside expanded Working for.")
        XCTAssertTrue(legacyDynamicRow.waitToExist(timeout: 10), "The legacy dynamic call should remain inside expanded Working for.")
        XCTAssertFalse(commandRow.exists, "The active command should stay outside expanded Working for.")
        XCTAssertTrue(latestActiveRow.label.contains("In progress"))
        for identifier in ["item_fixture_mcp_call", "item_fixture_dynamic_call"] {
            let liveDuration = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-duration-\(identifier)").firstMatch
            XCTAssertTrue(liveDuration.exists, "Expanded Working for should show a live duration for \(identifier).")
            XCTAssertTrue(containsPositiveRunningDuration(liveDuration.value as? String ?? ""), "The live duration for \(identifier) should contain positive elapsed time in milliseconds.")
        }
        XCTAssertTrue(mcpRow.label.contains("In progress"))
        XCTAssertTrue(dynamicRow.label.contains("In progress"))
        // Leaving and reopening the task mid-turn lands on the same open section,
        // with this turn's calls still readable; a cold reopen cannot reconstruct
        // the live elapsed-time display the continuously-open window shows above,
        // so this checks status and content, not the running duration.
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: "Tool activity")
        XCTAssertTrue(activityDisclosure.waitToExist(timeout: 20))
        XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Expanded, down chevron" }, timeout: 15),
                      "Reopening a task mid-turn should land on the same open section instead of hiding the work behind Working for.")
        XCTAssertTrue(activityDetails.waitToExist(timeout: 10), "The reopened live turn should render its progress without a click.")
        XCTAssertTrue(mcpRow.waitToExist(timeout: 10), "Reopening mid-turn should still show in-flight calls inside Working for.")
        XCTAssertTrue(dynamicRow.waitToExist(timeout: 5))
        XCTAssertTrue(legacyDynamicRow.waitToExist(timeout: 5))
        XCTAssertTrue(mcpRow.label.contains("In progress"), "A reopened in-flight call should still read as in progress.")
        XCTAssertTrue(latestActiveRow.waitToExist(timeout: 10), "The reopened window should still show the latest active process outside Working for.")
        XCTAssertFalse(commandRow.exists, "The active command should stay outside expanded Working for after reopening.")
        // The open section is a default, not a lock: a reader can fold it mid-turn,
        // and it must stay folded across the activity updates that follow. The reopened window
        // follows the live turn to its bottom, which can leave the disclosure above the viewport.
        bringIntoTranscriptViewport(activityDisclosure, scrollView: element("conversation-scroll-view"))
        XCTAssertTrue(waitForStableFrame(activityDisclosure) && activityDisclosure.isHittable, "The open section's disclosure should be in view before folding it.")
        activityDisclosure.click()
        XCTAssertTrue(waitUntil({ !activityDetails.exists }, timeout: 5), "Collapsing mid-turn should hide this turn's activity rows.")
        XCTAssertFalse(element("codex-activity-row-item_fixture_mcp_call").exists)
        XCTAssertFalse(element("codex-activity-row-item_fixture_dynamic_call").exists)
        attachScreenshot(named: "A reader can fold the section while the turn runs")
        try "Finish the newest call first.\n".write(to: toolReleaseLatest, atomically: true, encoding: .utf8)
        // The finished command leaves the live slot outside the section; while the
        // section is folded it is rendered nowhere, which is the observable signal
        // that the update landed.
        XCTAssertTrue(waitUntil({ !latestActiveRow.exists }, timeout: 10),
                      "The completed command should leave the live activity slot to the still-running calls.")
        XCTAssertEqual(activityDisclosure.value as? String, "Collapsed, right chevron",
                       "An activity update arriving mid-turn must not reopen a section the reader folded.")
        XCTAssertFalse(activityDetails.exists, "The reader's mid-turn collapse should survive the completing command.")
        activityDisclosure.click()
        XCTAssertTrue(activityDetails.waitToExist(timeout: 5), "Expanded Working for should contain tool activity rows.")
        XCTAssertTrue(waitUntil({ commandRow.waitToExist(timeout: 0.1) }, timeout: 10), "A completed command should move inside Working for.")
        XCTAssertTrue(commandRow.label.contains("Completed"), "The command should read Completed once the section is reopened.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").count, 1)
        try "Release tool completions.\n".write(to: toolRelease, atomically: true, encoding: .utf8)
        func activityRow(_ id: String) -> XCUIElement {
            element("codex-activity-details").descendants(matching: .any).matching(identifier: "codex-activity-row-\(id)").firstMatch
        }
        func activityRowShows(_ id: String, _ status: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "codex-activity-row-\(id)", status
            )).firstMatch.exists
        }
        // The live command row completes inside Working for; settled history lists tool calls.
        XCTAssertTrue(waitUntil({ activityRowShows("item_fixture_active_long_command", "Completed") }, timeout: 15), "The long command should complete inside Working for.")
        // The final answer folds the turn's activity into Worked for; reopen it once settled.
        XCTAssertTrue(waitUntil({ self.element("codex-activity-disclosure").exists && self.element("codex-activity-disclosure").label.hasPrefix("Worked for") }, timeout: 30), "The turn should settle into Worked for.")
        XCTAssertEqual(element("codex-activity-disclosure").value as? String, "Collapsed, right chevron",
                       "The final answer should fold the open section back into a clean Worked for.")
        attachScreenshot(named: "Worked for closes when the final answer arrives")
        var activityDetailsReopenCount = 0
        XCTAssertTrue(waitUntil({
            if !self.element("codex-activity-details").exists, activityDetailsReopenCount < 3 {
                self.element("codex-activity-disclosure").click()
                activityDetailsReopenCount += 1
                return false
            }
            let shown = activityRowShows("item_fixture_mcp_call", "Completed")
                && activityRowShows("item_fixture_dynamic_call", "Failed")
                && activityRowShows("item_fixture_dynamic_legacy", "Completed")
            // Expanded rows can extend below the visible transcript.
            if !shown { self.element("conversation-scroll-view").scroll(byDeltaX: 0, deltaY: -200) }
            return shown
        }, timeout: 30), "Lifecycle completions should update the existing rows.")
        let completedMcpRow = activityRow("item_fixture_mcp_call")
        let completedDynamicRow = activityRow("item_fixture_dynamic_call")
        let completedLegacyDynamicRow = activityRow("item_fixture_dynamic_legacy")
        XCTAssertTrue(completedMcpRow.label.contains("MCP · lookup"))
        XCTAssertTrue(rowText("item_fixture_mcp_call").contains("fixture-server"))
        XCTAssertTrue(rowText("item_fixture_mcp_call").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(rowText("item_fixture_mcp_call")), "The completed MCP call should display its positive measured duration in milliseconds.")
        XCTAssertTrue(rowText("item_fixture_dynamic_call").contains("Tool call failed"))
        XCTAssertTrue(rowText("item_fixture_dynamic_call").contains("Duration · 37 ms"))
        XCTAssertTrue(completedDynamicRow.label.contains("Tool · summarize"))
        XCTAssertTrue(completedLegacyDynamicRow.label.contains("Tool · legacySummary"))
        XCTAssertTrue(rowText("item_fixture_dynamic_legacy").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(rowText("item_fixture_dynamic_legacy")), "The completed legacy call should display its positive measured duration in milliseconds.")
        let renderedToolRows = "\(completedMcpRow.label) \(rowText("item_fixture_mcp_call")) \(completedDynamicRow.label) \(rowText("item_fixture_dynamic_call")) \(completedLegacyDynamicRow.label) \(rowText("item_fixture_dynamic_legacy"))"
        XCTAssertFalse(renderedToolRows.contains("RAW_ARGUMENT_SECRET"))
        XCTAssertFalse(renderedToolRows.contains("RAW_RESULT_SECRET"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").count, 1)

        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let savedActivities = history?["activities"] as? [[String: Any]] ?? []
        XCTAssertEqual(savedActivities.filter { $0["id"] as? String == "item_fixture_mcp_call" }.count, 1)
        XCTAssertEqual(savedActivities.filter { $0["id"] as? String == "item_fixture_dynamic_call" }.count, 1)
        element("back-to-board-button").click()
        openTask(named: "Tool activity")
        element("codex-activity-disclosure").click()
        let reloadedActivityDetails = element("codex-activity-details")
        XCTAssertTrue(reloadedActivityDetails.waitToExist(timeout: 5))
        let reloadedMcpRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").firstMatch
        XCTAssertTrue(reloadedMcpRow.waitToExist(timeout: 20), "Completed MCP activity should remain in Working for after history reload.")
        let reloadedDynamicRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").firstMatch
        let reloadedLegacyDynamicRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").firstMatch
        XCTAssertTrue(reloadedDynamicRow.waitToExist(timeout: 10), "Failed dynamic activity should remain after history reload.")
        XCTAssertTrue(reloadedLegacyDynamicRow.waitToExist(timeout: 10), "Legacy dynamic activity should remain after history reload.")
        XCTAssertTrue(reloadedMcpRow.label.contains("MCP · lookup"))
        XCTAssertTrue(reloadedMcpRow.label.contains("Completed"))
        XCTAssertTrue(rowText("item_fixture_mcp_call").contains("fixture-server"))
        XCTAssertTrue(rowText("item_fixture_mcp_call").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(rowText("item_fixture_mcp_call")), "The positive MCP duration must survive history reload in milliseconds.")
        XCTAssertTrue(reloadedDynamicRow.label.contains("Tool · summarize"))
        XCTAssertTrue(reloadedDynamicRow.label.contains("Failed"))
        XCTAssertTrue(rowText("item_fixture_dynamic_call").contains("Tool call failed"))
        XCTAssertTrue(rowText("item_fixture_dynamic_call").contains("Duration · 37 ms"), "Optional duration should survive history reload and render.")
        XCTAssertTrue(reloadedLegacyDynamicRow.label.contains("Tool · legacySummary"))
        XCTAssertTrue(reloadedLegacyDynamicRow.label.contains("Completed"))
        XCTAssertTrue(rowText("item_fixture_dynamic_legacy").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(rowText("item_fixture_dynamic_legacy")), "The positive legacy tool duration must survive history reload in milliseconds.")
        let reloadedToolRows = reloadedMcpRow.label + " " + rowText("item_fixture_mcp_call")
            + " " + reloadedDynamicRow.label + " " + rowText("item_fixture_dynamic_call")
            + " " + reloadedLegacyDynamicRow.label + " " + rowText("item_fixture_dynamic_legacy")
        XCTAssertFalse(reloadedToolRows.contains("RAW_ARGUMENT_SECRET"))
        XCTAssertFalse(reloadedToolRows.contains("RAW_RESULT_SECRET"))
    }
    // case-contract: test_conversation_shows_context_compaction | contextCompaction item/started and item/completed coalesce into one concise timeline event; missing summaries ignore malformed opaque payload fields and never render their data, and the event survives a fresh history reload from Playhouse's transcript store with correct prompt/response ordering.
    func test_conversation_shows_context_compaction() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-context-compaction").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(codexFixtureExecutable)))
        launchApp(defaultParent: fixture.primary.path)
        _ = try runCLI(["task", "create", "--title", "Context compaction", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Context compaction")
        openTask(named: "Context compaction")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Compact the context.")
        element("send-message-button").click()

        let executable = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable))
        let ready = URL(fileURLWithPath: executable.path + ".compaction-ready")
        let release = URL(fileURLWithPath: executable.path + ".compaction-release")
        defer { try? "Release compaction after assertion failure.\n".write(to: release, atomically: true, encoding: .utf8) }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20))
        let row = element("context-compaction-row-item_playhouse_compaction")
        XCTAssertTrue(row.waitToExist(timeout: 10))
        XCTAssertTrue(row.label.contains("In progress"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_playhouse_compaction").count, 1)
        XCTAssertFalse((row.label + " " + (row.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        try "Release context compaction.\n".write(to: release, atomically: true, encoding: .utf8)
        // Query by label: reading `row.label` while the reload below briefly removes the
        // row is a fatal snapshot error, not a polled false.
        let completedRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "context-compaction-row-item_playhouse_compaction", "Completed"
        )).firstMatch
        XCTAssertTrue(waitUntil({ completedRow.exists }, timeout: 20))
        // The turn's end reloads the transcript; the row is briefly absent while
        // that happens, so wait for the reloaded state before counting rows.
        XCTAssertTrue(waitUntil({
            app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_playhouse_compaction").count == 1
        }, timeout: 5), "The completed compaction should remain exactly one row after the transcript reloads.")
        XCTAssertFalse((row.label + " " + (row.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        let finalMessage = app.staticTexts["Context compaction completed."]
        XCTAssertTrue(finalMessage.waitToExist(timeout: 10))
        XCTAssertLessThan(row.frame.minY, finalMessage.frame.minY)
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [[String: Any]] ?? []).filter { $0["isContextCompaction"] as? Bool == true }.count, 1)
        element("back-to-board-button").click()
        openTask(named: "Context compaction")
        let reloaded = element("context-compaction-row-item_playhouse_compaction")
        XCTAssertTrue(reloaded.waitToExist(timeout: 20))
        XCTAssertTrue(reloaded.label.contains("Completed"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_playhouse_compaction").count, 1)
        XCTAssertFalse((reloaded.label + " " + (reloaded.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        XCTAssertLessThan(reloaded.frame.minY, app.staticTexts["Context compaction completed."].frame.minY)
    }
    // case-contract: test_conversation_loads_newest_messages_before_older_history | Reopening a 120-message conversation, whose turns Playhouse holds in its own store, immediately presents only the latest user question, pinned to the top of the viewport with its answer below, which is taller than the viewport and runs on past its bottom. Scrolling upward reveals earlier messages automatically, a few at a time, starting from a reader already at the top of the rendered messages; they are revealed while the reader is near the oldest rendered message and stop once the reader rests away from it, while the message the reader is on stays in place and chronological order is preserved. A conversation that was empty when it opened establishes no window: when its sent turn streams sixty replies, each stored as its own message in order, it keeps the newest 40 of those 61 messages rendered as they arrive. Reopened once that turn settles, its sixty replies, all the turn's own with none of them progress that collapses, make a newest turn far longer than what a conversation renders when it opens: it opens at its end on the newest reply, renders only the messages above it that fill the viewport (more than the six it opens with, fewer than 40) and not the turn's question, and scrolling up reveals the earlier replies and reaches that question. An in-place provider switch keeps the revealed history and the reader on the newest message, with the switch's divider below it; reopening the conversation after it opens on that same latest turn, pinned the same way, and keeps upward paging working: scrolling on to the top reveals every message, reading the stored page as needed, and reaches the first messages. CLI/XPC history remains complete and ordered across fresh reads and across an in-place provider switch, and a paged read returns only the newest 80 messages with the count of the 40 before them, while paging backward returns those earlier messages in order.
    func test_conversation_loads_newest_messages_before_older_history() throws {
        let fixtureCopy = WorkspaceFixture.root.appendingPathComponent("codex-fixture-long-history-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the long-history fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        // The case switches provider to reload history in place; the Claude
        // fixture keeps that switch from reaching an installed Claude CLI.
        let claudeExecutable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: claudeExecutable.path), "The UI runner must prepare the Claude fixture before launch.")
        claudeFixtureExecutable = claudeExecutable.path
        launchApp(defaultParent: fixture.primary.path)
        try createTaskFixture(title: "Long conversation history", roots: [fixture.primary.path])
        openTask(named: "Long conversation history")

        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Create a long history.")
        element("send-message-button").click()

        let latest = element("assistant-message-item_long_history_assistant_60")
        let latestQuestion = element("user-message-item_long_history_user_60")
        let oldest = element("user-message-item_long_history_user_1")
        // A conversation that was empty when it opened establishes no window, so the sent
        // turn's sixty replies keep the newest batch rendered rather than collapsing to the
        // turn being answered.
        let liveScrollView = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            liveScrollView.value as? String == "Showing latest 40 of 61 messages"
        }, timeout: 20), "A live session should keep the newest batch rendered, not collapse to the latest turn.")
        XCTAssertTrue(transcriptMessage("Live long history reply 60.").waitToExist(timeout: 10), "The newest live reply is rendered.")
        attachScreenshot(named: "long-history-0-live-newest-batch")
        XCTAssertTrue(waitUntil({
            !self.element("codex-working-duration").exists && self.noTurnIsRunning()
        }, timeout: 20), "The sent turn should settle before earlier history is seeded.")
        // The settled turn's sixty replies are its own, so the newest turn is far longer than
        // what a conversation renders when it opens. Reopened, it opens at its end on its newest
        // messages, and only the messages above them that fill the viewport render with them.
        let seededTaskID = try taskID(named: "Long conversation history")
        let liveHistory = try XCTUnwrap(try runCLI(["conversation", "history", seededTaskID])["result"] as? [String: Any])
        let liveQuestionID = try XCTUnwrap(((liveHistory["messages"] as? [[String: Any]])?.first)?["id"] as? String)
        openTask(named: "Long conversation history")
        let reopenedLive = element("conversation-scroll-view")
        func reopenedLiveCount() -> Int {
            (reopenedLive.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? 0
        }
        let newestLiveReply = transcriptMessage("Live long history reply 60.")
        XCTAssertTrue(waitUntil({
            (reopenedLive.value as? String ?? "").hasSuffix(" of 61 messages") && newestLiveReply.exists
                && reopenedLive.frame.intersects(newestLiveReply.frame)
        }, timeout: 20), "Reopening a long newest turn should show its newest reply; value=\(reopenedLive.value as? String ?? "nil").")
        // The window fills the viewport a few messages at a time, then rests.
        var settledCount = reopenedLiveCount()
        var settledSince = Date()
        XCTAssertTrue(waitUntil({
            let count = reopenedLiveCount()
            if count != settledCount { settledCount = count; settledSince = Date() }
            return Date().timeIntervalSince(settledSince) >= 1.5
        }, timeout: 15), "The opening window should stop growing once the viewport is full.")
        // Six messages open the window; one-line replies that short leave the viewport to fill.
        XCTAssertGreaterThan(settledCount, 6, "The messages above the newest few should render until they fill the viewport; rendered=\(settledCount).")
        XCTAssertLessThan(settledCount, 40, "Opening should not render the whole long turn; rendered=\(settledCount).")
        XCTAssertFalse(element("user-message-\(liveQuestionID)").exists, "The long turn's question stays unrendered until the reader scrolls up to it.")
        XCTAssertGreaterThanOrEqual(newestLiveReply.frame.maxY, reopenedLive.frame.maxY - 140,
                                    "The long turn opens at its end; reply=\(newestLiveReply.frame), viewport=\(reopenedLive.frame).")
        XCTAssertLessThanOrEqual(newestLiveReply.frame.maxY, reopenedLive.frame.maxY + 4,
                                 "The newest reply is fully in view, not cut off below it; reply=\(newestLiveReply.frame), viewport=\(reopenedLive.frame).")
        attachScreenshot(named: "long-history-1-long-turn-opens-at-end")
        reopenedLive.scroll(byDeltaX: 0, deltaY: 1500)
        XCTAssertTrue(waitUntil({ reopenedLiveCount() > settledCount }, timeout: 10),
                      "Scrolling up should reveal the long turn's earlier replies.")
        reopenedLive.scroll(byDeltaX: 0, deltaY: 40_000)
        for _ in 0..<40 {
            guard !element("user-message-\(liveQuestionID)").exists else { break }
            reopenedLive.scroll(byDeltaX: 0, deltaY: 1500)
            _ = waitUntil({ self.element("user-message-\(liveQuestionID)").exists }, timeout: 0.5)
        }
        XCTAssertTrue(element("user-message-\(liveQuestionID)").waitToExist(timeout: 5), "Scrolling up reaches the long turn's question.")
        attachScreenshot(named: "long-history-2-long-turn-question-revealed")
        // Earlier sessions' turns are already in Playhouse's own store; the provider holds none of them.
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before its stored history is seeded.")
        try seedLongHistory(seededTaskID, tallLatestAnswer: true)
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        openTask(named: "Long conversation history")
        let scrollView = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            scrollView.value as? String == "Showing latest 2 of 120 messages"
        }, timeout: 20), "Reopening should render only the latest user turn.")
        XCTAssertTrue(latestQuestion.exists, "The latest user question should be rendered with its answer.")
        XCTAssertTrue(latestQuestion.isHittable, "The latest user question should be visible immediately.")
        XCTAssertTrue(latest.exists, "Reopening a populated conversation should immediately present the newest message.")
        XCTAssertTrue(scrollView.frame.intersects(latest.frame), "The newest message should be visible as soon as the latest page loads.")
        // The newest answer is taller than the viewport, so a conversation opened at its end
        // rather than on its question would have carried the question out of view.
        func assertPinnedToLatestQuestion(_ context: String) {
            let topGap = latestQuestion.frame.minY - scrollView.frame.minY
            XCTAssertGreaterThanOrEqual(topGap, -30, "\(context): the latest question should not start above the viewport; gap=\(topGap).")
            XCTAssertLessThanOrEqual(topGap, 120, "\(context): the latest question should be pinned to the top of the viewport; gap=\(topGap).")
            XCTAssertGreaterThan(latest.frame.minY, latestQuestion.frame.minY, "\(context): the latest answer should be rendered below the latest question.")
            XCTAssertGreaterThan(latest.frame.maxY, scrollView.frame.maxY, "\(context): the latest answer should run on past the bottom of the viewport, not be scrolled to its end; answer=\(latest.frame), viewport=\(scrollView.frame).")
        }
        assertPinnedToLatestQuestion("Reopening")
        XCTAssertFalse(oldest.exists, "Older messages should not be rendered in the initial message window.")
        let longTaskID = try taskID(named: "Long conversation history")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", longTaskID])["result"] as? [String: Any])
        let allMessages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        XCTAssertEqual(allMessages.count, 120, "The CLI should retain complete history while the UI renders a recent window.")
        let newestPage = try XCTUnwrap(try runCLI(["conversation", "history", longTaskID, "--limit", "80"])["result"] as? [String: Any])
        let newestMessages = try XCTUnwrap(newestPage["messages"] as? [[String: Any]])
        XCTAssertEqual(newestPage["earlierMessageCount"] as? Int, 40, "A paged read reports the messages left before it.")
        XCTAssertEqual(newestMessages.compactMap { $0["text"] as? String }, allMessages[40...].compactMap { $0["text"] as? String })
        let olderPage = try XCTUnwrap(try runCLI([
            "conversation", "history", longTaskID, "--limit", "80", "--before", try XCTUnwrap(newestMessages.first?["id"] as? String),
        ])["result"] as? [String: Any])
        XCTAssertEqual(olderPage["earlierMessageCount"] as? Int, 0)
        XCTAssertEqual((olderPage["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, allMessages[..<40].compactMap { $0["text"] as? String })

        let intermediate = element("user-message-item_long_history_user_21")
        let firstLoadedUser = element("user-message-item_long_history_user_40")
        // Wheel scrolling keeps the gesture deterministic: a swipe carries
        // momentum past the newly revealed messages.
        func renderedCount() -> Int {
            (scrollView.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? 0
        }
        func isVisible(_ candidate: XCUIElement) -> Bool {
            candidate.exists && scrollView.frame.intersects(candidate.frame)
        }
        func scrollTranscript(by delta: CGFloat, until condition: () -> Bool, limit: Int = 40, settle: TimeInterval = 0) {
            for _ in 0..<limit {
                guard !condition() else { break }
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
                // Revealing messages and restoring their anchor is asynchronous;
                // scrolling again before it lands would move past the anchor.
                if settle > 0 { _ = waitUntil(condition, timeout: settle) }
            }
        }
        XCTAssertEqual(scrollView.value as? String, "Showing latest 2 of 120 messages", "Opening the conversation must not render earlier turns.")
        XCTAssertFalse(intermediate.exists, "The first message in the excluded prior page should not be rendered before scrolling.")
        attachScreenshot(named: "Reopened on the latest question")
        scrollView.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertTrue(waitUntil({ renderedCount() > 2 }, timeout: 10), "An upward scroll should reveal older messages when the reader is already at the top of the rendered messages.")
        XCTAssertTrue(waitUntil({ isVisible(latestQuestion) }, timeout: 5), "Revealing older messages should keep the message the reader was on in view instead of jumping.")
        // Older messages are revealed a few at a time and only while the reader is near the
        // oldest rendered one, so a short scroll reveals a short stretch of them. The question
        // moves down by no more than the scroll itself.
        XCTAssertLessThanOrEqual(abs(latestQuestion.frame.minY - scrollView.frame.minY), 350, "The message that was at the top should stay where the scroll left it when older messages are inserted above it.")
        XCTAssertLessThan(renderedCount(), 80, "A short scroll should not reveal the history far above the reader; rendered=\(renderedCount()).")
        XCTAssertFalse(isVisible(oldest), "The first older messages should not yet reach the oldest message.")
        attachScreenshot(named: "Older messages revealed above the latest question")

        scrollTranscript(by: 400, until: { isVisible(firstLoadedUser) }, limit: 80, settle: 0.3)
        XCTAssertTrue(waitUntil({ isVisible(firstLoadedUser) }, timeout: 5), "Scrolling toward the top should keep revealing older messages to scroll into.")
        // Messages keep being revealed above the reader while one they can see stays where it
        // is. Had the viewport not held its place, each insertion would have carried the reader
        // into older messages, revealing more, until the whole history had rendered.
        XCTAssertTrue(waitUntil({ renderedCount() > 42 }, timeout: 5), "The messages above the one the reader reached should be rendered ahead of them; rendered=\(renderedCount()).")
        let restingTop = firstLoadedUser.frame.minY
        let restingCount = renderedCount()
        XCTAssertFalse(waitUntil({ abs(firstLoadedUser.frame.minY - restingTop) > 20 }, timeout: 2), "Revealing older messages should not move the message the reader is on.")
        XCTAssertGreaterThanOrEqual(renderedCount(), restingCount, "Revealed messages stay rendered.")
        XCTAssertLessThan(renderedCount(), 120, "Automatic pagination should stop while the reader rests away from the top; rendered=\(renderedCount()).")
        XCTAssertFalse(isVisible(oldest), "The oldest page should still be out of view.")
        attachScreenshot(named: "Older messages keep revealing above the reader")
        scrollTranscript(by: 1500, until: { scrollView.value as? String == "Showing latest 120 of 120 messages" }, limit: 80, settle: 0.5)
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages")
        scrollTranscript(by: 1500, until: { isVisible(oldest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(oldest) }, timeout: 5), "Scrolling to the top should bring the oldest message into view.")
        let firstAssistant = element("assistant-message-item_long_history_assistant_1")
        XCTAssertTrue(waitUntil({ isVisible(firstAssistant) }, timeout: 5))
        XCTAssertLessThan(oldest.frame.minY, firstAssistant.frame.minY, "Older messages should retain chronological order after they are inserted.")
        let lastOlderAssistant = element("assistant-message-item_long_history_assistant_59")
        // Step by less than the overlap between adjacent rows so a large scroll cannot
        // jump past the position where the last older answer and latest turn are both visible.
        scrollTranscript(by: -200, until: { isVisible(lastOlderAssistant) && isVisible(latestQuestion) }, limit: 60, settle: 0.2)
        XCTAssertTrue(waitUntil({ isVisible(lastOlderAssistant) }, timeout: 5), "The last earlier answer should remain reachable after all pages load.")
        XCTAssertTrue(waitUntil({ isVisible(latestQuestion) }, timeout: 5), "The start of the initially rendered latest turn should be reachable.")
        XCTAssertLessThan(lastOlderAssistant.frame.minY, latestQuestion.frame.minY, "Earlier history should remain in chronological order across the boundary into the latest turn.")
        attachScreenshot(named: "Older answer remains ordered above the latest question")
        scrollTranscript(by: -1500, until: { isVisible(latest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(latest) }, timeout: 5), "Loading earlier messages should preserve and return to the newest content.")

        // A provider switch only decides who runs the next turn, so the transcript stays as the
        // reader left it: every revealed message, with the reader still at the newest one. The
        // switch's divider goes below it, and the view stays at the end to show the divider.
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ providerMenu.isEnabled }, timeout: 10), "The provider menu should be available once the long history settles.")
        providerMenu.click()
        let claudeChoice = app.menuItems["conversation-provider-claude"]
        XCTAssertTrue(claudeChoice.waitToExist(timeout: 5))
        claudeChoice.click()
        XCTAssertTrue(waitUntil({ providerMenu.value as? String == "claude" }, timeout: 10), "The conversation switches to Claude in place.")
        XCTAssertFalse(waitUntil({ scrollView.value as? String != "Showing latest 120 of 120 messages" }, timeout: 3),
                       "Switching providers keeps the revealed history; value=\(scrollView.value as? String ?? "nil").")
        let divider = element("provider-boundary-claude")
        XCTAssertTrue(waitUntil({ isVisible(divider) }, timeout: 5), "The switch's divider shows at the end of the transcript.")
        XCTAssertTrue(isVisible(latest), "Switching providers keeps the reader on the newest message.")
        XCTAssertGreaterThan(divider.frame.minY, latest.frame.maxY - 1, "The divider sits below the newest message.")
        XCTAssertLessThanOrEqual(divider.frame.maxY, scrollView.frame.maxY + 1, "The view stays at the end, with the divider fully in view; divider=\(divider.frame), viewport=\(scrollView.frame).")
        // The menu shows a switch before it is saved and returns to Codex if saving fails, so
        // the switch counts only once the task records it and the menu still reads Claude.
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longTaskID))?["conversationProvider"] as? String == "claude" }, timeout: 10),
                      "The task records the switch to Claude.")
        XCTAssertEqual(providerMenu.value as? String, "claude", "The switch holds once saved.")
        XCTAssertFalse(element("codex-chat-error").exists, "The switch saves without an error.")
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages", "Saving the switch keeps the revealed history too.")
        attachScreenshot(named: "A provider switch keeps the revealed history")

        // Reopened, the conversation opens on the latest turn again and upward paging works
        // from that fresh window.
        element("back-to-board-button").click()
        openTask(named: "Long conversation history")
        XCTAssertTrue(waitUntil({
            scrollView.value as? String == "Showing latest 2 of 120 messages"
        }, timeout: 20), "Reopening after the switch should open on the latest turn instead of keeping the revealed history.")
        XCTAssertEqual(element("conversation-provider-menu").value as? String, "claude", "The reopened conversation keeps the saved switch.")
        XCTAssertTrue(waitUntil({ isVisible(latestQuestion) }, timeout: 5), "The latest question should be visible again after reopening.")
        assertPinnedToLatestQuestion("Reopening after the switch")
        attachScreenshot(named: "Reopening after the switch opens on the latest question")
        XCTAssertFalse(oldest.exists, "Reopening should not keep older messages rendered.")
        scrollView.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertTrue(waitUntil({ renderedCount() > 2 }, timeout: 10), "Upward scrolling must still reveal earlier messages after reopening.")
        // Long upward scrolls, as dragging the scroller's knob to the top does, each land on the
        // oldest rendered message and reveal the messages above it, including the page still in
        // the store, until the first messages are reached.
        XCTAssertTrue(revealWholeTranscript(step: 40_000, timeout: 90), "Scrolling on to the top of the history should reveal every message above the window.")
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages")
        scrollTranscript(by: 40_000, until: { isVisible(oldest) }, limit: 5, settle: 1)
        XCTAssertTrue(waitUntil({ isVisible(oldest) }, timeout: 5), "Scrolling on to the top of the history should land on its first messages.")
        attachScreenshot(named: "Scrolling to the top of the history lands on the first messages")
    }
}

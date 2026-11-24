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
    // case-contract: test_conversation_settled_history_renders_lazily | In a 120-message conversation whose history has been revealed, the messages before the newest turn render lazily: once the reader is back at the latest turn, the oldest messages that scrolled far out of view are no longer kept as views, and they render again, in order, when the reader scrolls back to them. A message scrolled away and back by the same distance lands where it was. A command an earlier turn ran stays inline after the message it followed, with its whole output in fresh CLI/XPC history, and a call the reader expanded is still expanded when its row renders again. A message holding an open side chat keeps rendering while the reader scrolls far away, so its bubble and unsent draft are still there when the reader returns. Changing the transcript's width keeps the reader on the message they were reading, with the older messages above still in order.
    func test_conversation_settled_history_renders_lazily() throws {
        let fixtureCopy = WorkspaceFixture.root.appendingPathComponent("codex-fixture-long-history-lazy-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the lazy long-history fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        launchApp(defaultParent: fixture.primary.path)
        let title = "Lazy long history"
        try createTaskFixture(title: title, roots: [fixture.primary.path])
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Create a long history.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ !self.element("codex-working-duration").exists && self.noTurnIsRunning() }, timeout: 30),
                      "The sent turn should settle before earlier history is seeded.")
        let taskID = try taskID(named: title)
        // Earlier sessions' turns are already in Playhouse's own store; the provider holds none of them.
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before its stored history is seeded.")
        try seedLongHistory(taskID, midHistoryCommand: true)
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertEqual((history["messages"] as? [[String: Any]])?.count, 120, "CLI/XPC history stays complete while the transcript renders lazily.")
        let call = try XCTUnwrap((history["timelineActivities"] as? [[String: Any]])?.first { $0["id"] as? String == "item_long_history_command_21" },
                                 "The earlier turn's command should be a timeline activity in fresh history.")
        XCTAssertEqual(call["afterMessageID"] as? String, "item_long_history_user_21", "The command follows the question of its own turn.")
        XCTAssertEqual((call["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").count, 6,
                       "Fresh history keeps the command's whole output.")
        openTask(named: title)

        let scrollView = element("conversation-scroll-view")
        let latest = element("assistant-message-item_long_history_assistant_60")
        let oldest = element("user-message-item_long_history_user_1")
        let firstAssistant = element("assistant-message-item_long_history_assistant_1")
        let intermediate = element("user-message-item_long_history_user_21")
        let callRow = element("conversation-tool-call-item_long_history_command_21")
        let callOutput = element("conversation-tool-call-output-item_long_history_command_21")
        func isVisible(_ candidate: XCUIElement) -> Bool {
            candidate.exists && scrollView.frame.intersects(candidate.frame)
        }
        func topInViewport(_ candidate: XCUIElement) -> CGFloat { candidate.frame.minY - scrollView.frame.minY }
        // Wheel scrolling keeps each step deterministic: a swipe carries momentum.
        func scrollTranscript(by delta: CGFloat, until condition: () -> Bool, limit: Int = 40, settle: TimeInterval = 0) {
            for _ in 0..<limit {
                guard !condition() else { break }
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
                if settle > 0 { _ = waitUntil(condition, timeout: settle) }
            }
        }
        /// Coarse steps until `target` is rendered, which it is well before it reaches the
        /// viewport, so a step cannot carry past it; then into view, then steps shorter than the
        /// 160-point band below the viewport's top, so the seek cannot carry it past that band.
        func bringNearTop(_ target: XCUIElement, coarse: CGFloat) {
            scrollTranscript(by: coarse, until: { target.exists }, limit: 40, settle: 0.2)
            bringIntoTranscriptViewport(target, scrollView: scrollView)
            let fine: CGFloat = coarse < 0 ? -100 : 100
            scrollTranscript(by: fine, until: { isVisible(target) && topInViewport(target) < 160 && topInViewport(target) >= 0 }, limit: 20, settle: 0.2)
        }
        XCTAssertTrue(waitUntil({ scrollView.value as? String == "Showing latest 2 of 120 messages" }, timeout: 20), "Reopening should render only the latest turn.")
        // A short scroll reveals the first older messages; long upward scrolls then each land on
        // the oldest rendered message and reveal the messages above it.
        scrollView.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertTrue(waitUntil({ scrollView.value as? String != "Showing latest 2 of 120 messages" }, timeout: 10), "An upward scroll should reveal the first older messages.")
        XCTAssertTrue(revealWholeTranscript(step: 40_000, timeout: 90), "Scrolling up should reveal every earlier message.")
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages")
        scrollTranscript(by: 1500, until: { isVisible(oldest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(oldest) && isVisible(firstAssistant) }, timeout: 5), "The top of the revealed history should show its first messages.")

        // Back at the newest turn, the oldest rows are far out of view and no longer exist as
        // views. An eager transcript keeps every revealed row, which made scrolling, hit testing
        // and layout cost grow with the history.
        scrollTranscript(by: -1500, until: { isVisible(latest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(latest) }, timeout: 5))
        XCTAssertTrue(waitUntil({ !oldest.exists && !firstAssistant.exists }, timeout: 5), "Rows scrolled far out of view should not stay rendered once the reader returns to the latest turn.")
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages", "Lazy rendering must keep every revealed message in the transcript's window.")
        // The discarded rows are rebuilt when the reader returns to them, still in order.
        scrollTranscript(by: 1500, until: { isVisible(oldest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(oldest) && isVisible(firstAssistant) }, timeout: 5), "Scrolling back up should render the oldest messages again.")
        XCTAssertLessThan(oldest.frame.minY, firstAssistant.frame.minY, "Rebuilt rows should keep chronological order.")
        XCTAssertEqual(scrollView.value as? String, "Showing latest 120 of 120 messages", "Returning to discarded rows must not reload or shrink the window.")

        // The earlier turn's command renders inline after its question; expanding it shows every line.
        bringNearTop(intermediate, coarse: -900)
        XCTAssertTrue(isVisible(intermediate), "A mid-history message should be reachable once every batch is revealed.")
        XCTAssertTrue(waitUntil({ isVisible(callRow) }, timeout: 5), "The earlier turn's command should render inline after its question.")
        XCTAssertLessThan(intermediate.frame.minY, callRow.frame.minY, "The command should follow the message it came after.")
        XCTAssertTrue(scrollFullyIntoView(callRow, in: scrollView))
        XCTAssertFalse(callOutput.exists, "A collapsed shell call shows only its one-line command preview.")
        let toggle = element("conversation-tool-call-toggle-item_long_history_command_21")
        XCTAssertTrue(toggle.waitToExist(timeout: 5), "A shell call can expand.")
        toggle.click()
        XCTAssertTrue(waitUntil({ callOutput.exists && callOutput.frame.height > 60 }, timeout: 5), "Expanding should show every output line.")
        let expandedOutputHeight = callOutput.frame.height
        bringNearTop(intermediate, coarse: 300)

        // A row that leaves the viewport's surroundings becomes a box of its measured height, so
        // scrolling away and back by the same distance lands it exactly where it was, and the
        // call the reader expanded is still expanded when its row is rebuilt.
        let intermediateTop = topInViewport(intermediate)
        for _ in 0..<2 { scrollView.scroll(byDeltaX: 0, deltaY: -1500) }
        XCTAssertTrue(waitUntil({ !intermediate.exists && !callRow.exists }, timeout: 5), "Rows scrolled far away should no longer be rendered.")
        for _ in 0..<2 { scrollView.scroll(byDeltaX: 0, deltaY: 1500) }
        XCTAssertTrue(waitUntil({ isVisible(intermediate) }, timeout: 5), "Scrolling back should render the message again.")
        XCTAssertLessThanOrEqual(abs(topInViewport(intermediate) - intermediateTop), 20,
                                 "Unrendered messages must keep their real heights, so a round trip lands the message where it was.")
        XCTAssertTrue(waitUntil({ callOutput.exists && abs(callOutput.frame.height - expandedOutputHeight) <= 2 }, timeout: 5),
                      "A call the reader expanded should still be expanded when its row is rebuilt.")
        attachScreenshot(named: "Rebuilt rows land where they were with the call still expanded")

        // A message holding an open side chat keeps rendering however far the reader scrolls, so
        // its bubble, which is anchored in the message's text, keeps its unsent draft.
        let userText = intermediate.textViews.firstMatch
        XCTAssertTrue(userText.waitToExist(timeout: 5))
        userText.click()
        userText.typeKey("a", modifierFlags: .command)
        let bubble = try waitForSideChatBubble(at: intermediate)
        let sideChatInput = element("side-chat-input")
        XCTAssertTrue(sideChatInput.waitToExist(timeout: 5))
        sideChatInput.click()
        sideChatInput.typeText("Keep this side chat draft.")
        // Scroll from below the bubble, so the wheel reaches the transcript rather than the bubble.
        let belowBubble = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        for _ in 0..<2 { belowBubble.scroll(byDeltaX: 0, deltaY: -1500) }
        XCTAssertTrue(waitUntil({ !self.element("user-message-item_long_history_user_22").exists }, timeout: 5),
                      "The rows around the selected message should still turn into boxes once far away.")
        XCTAssertTrue(intermediate.exists, "The message holding the side chat should keep rendering while far away.")
        XCTAssertTrue(bubble.exists, "The side chat bubble should stay open while its message is scrolled away.")
        for _ in 0..<2 { belowBubble.scroll(byDeltaX: 0, deltaY: 1500) }
        XCTAssertTrue(waitUntil({ isVisible(intermediate) && bubble.exists }, timeout: 5), "Back at the message, its side chat should still be open.")
        XCTAssertEqual(sideChatInput.value as? String, "Keep this side chat draft.", "The side chat keeps its unsent draft.")
        attachScreenshot(named: "Side chat stays open on a message scrolled far away and back")
        sideChatInput.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !bubble.exists }, timeout: 5), "Escape should close the side chat.")

        // A width change keeps the reader on the message they were reading, and the older
        // messages above, whose heights were taken at the old width, still render in order.
        // The message read sits deep in the history, so the boxes above it are tall enough that
        // their rescaled heights, if the reader's position were not restored, would carry it far
        // further than the tolerance below: the restore pins the message at the viewport's top
        // to the top again, so the message read moves by at most one message.
        // The scroll content, padding included, is capped at 820 points; the rows are only as
        // wide as that capped column, so it is the column whose width must change. The window
        // opens wide enough on the test screen to leave the column capped with the task sidebar
        // shown or hidden, so first narrow the window to its minimum width, where the shown
        // sidebar leaves the column under the cap and hiding the sidebar widens it.
        func columnWidth(_ scrollWidth: CGFloat) -> CGFloat { min(scrollWidth, 820) }
        narrowWindowToMinimumWidth()
        XCTAssertTrue(waitUntil({ columnWidth(scrollView.frame.width) < 790 }, timeout: 5),
                      "Narrowing the window should bring the transcript's column under its cap: width=\(scrollView.frame.width).")
        XCTAssertTrue(waitForStableFrame(scrollView), "The narrowed transcript should settle.")
        let deepMessage = element("user-message-item_long_history_user_50")
        bringNearTop(deepMessage, coarse: -900)
        XCTAssertTrue(isVisible(deepMessage), "A message deep in the history should be reachable.")
        let widthBeforeResize = scrollView.frame.width
        let readingTop = topInViewport(deepMessage)
        let hideSidebar = element("hide-task-sidebar-button")
        XCTAssertTrue(waitUntil({ hideSidebar.exists && hideSidebar.isHittable }, timeout: 5), "The task sidebar should offer its hide button.")
        hideSidebar.click()
        XCTAssertTrue(waitUntil({ abs(columnWidth(scrollView.frame.width) - columnWidth(widthBeforeResize)) > 20 }, timeout: 5),
                      "Hiding the task sidebar should change the width of the transcript's column: before=\(widthBeforeResize), after=\(scrollView.frame.width).")
        // The sidebar animates away, so judge the position once the width has settled, not on
        // a sample taken while the rows were still reflowing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(isVisible(deepMessage) && abs(topInViewport(deepMessage) - readingTop) <= 100,
                      "A resize should keep the message being read in place; it moved from \(readingTop) to \(topInViewport(deepMessage)).")
        attachScreenshot(named: "A resize keeps the message being read in place")
        scrollTranscript(by: 1500, until: { isVisible(oldest) }, limit: 40)
        XCTAssertTrue(waitUntil({ isVisible(oldest) && isVisible(firstAssistant) }, timeout: 5), "The oldest messages should render after a resize.")
        XCTAssertLessThan(oldest.frame.minY, firstAssistant.frame.minY, "Messages measured at the old width should keep chronological order after a resize.")
        let showSidebar = element("show-task-sidebar-button")
        XCTAssertTrue(waitUntil({ showSidebar.exists && showSidebar.isHittable }, timeout: 5), "The hidden task sidebar should offer its show button.")
        showSidebar.click()
        XCTAssertTrue(waitUntil({ abs(scrollView.frame.width - widthBeforeResize) <= 2 }, timeout: 5), "Showing the task sidebar again should restore the transcript's width.")
    }
    // case-contract: test_sent_prompt_stays_out_of_composer_past_history_page | A sent prompt followed by 120 stored messages, so that it lies outside the newest history page, never returns to the composer when the task is reopened: the composer is empty, the task keeps hasUnsentDraft false and its last sent prompt as the saved prompt, and the CLI newest page of 80 messages leaves out the earlier messages. Only the saved draft flag decides draft restoration, so the same task restores a real unsent draft after it is typed.
    func test_sent_prompt_stays_out_of_composer_past_history_page() throws {
        let fixtureCopy = WorkspaceFixture.root.appendingPathComponent("codex-fixture-long-history-with-prompt-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the long-history fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        launchApp(defaultParent: fixture.primary.path)
        try createTaskFixture(title: "Sent prompt past history page", roots: [fixture.primary.path])
        openTask(named: "Sent prompt past history page")

        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Create a long history.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(named: "Sent prompt past history page") else { return false }
            return record["status"] as? String != "In Progress" && (record["pendingSubmittedPrompt"] as? String) == nil
        }, timeout: 20), "The sent turn should settle before the conversation is reopened.")
        // The 120 messages that follow the sent prompt are seeded into Playhouse's own store,
        // which holds the transcript; the provider holds none of it.
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before its stored history is seeded.")
        try seedLongHistory(try taskID(named: "Sent prompt past history page"), sentPrompt: true)
        launchAppWithOpen()
        waitForBoardOrAbortSuite()

        openTask(named: "Sent prompt past history page")
        let scrollView = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            scrollView.value as? String == "Showing latest 2 of 121 messages"
        }, timeout: 20), "Reopening should render only the newest page, which leaves the sent prompt's turn out.")
        // The composer restores drafts asynchronously after the history loads, so keep
        // checking that it stays empty for a moment rather than trusting the first frame.
        XCTAssertFalse(waitUntil({
            !((composer.value as? String) ?? "").isEmpty
        }, timeout: 2), "A sent prompt must not return to the composer as an unsent draft.")
        attachScreenshot(named: "Sent prompt stays out of composer after reopening past the history page")
        let taskID = try taskID(named: "Sent prompt past history page")
        let sentRecord = try XCTUnwrap(try taskRecord(id: taskID))
        XCTAssertEqual(sentRecord["hasUnsentDraft"] as? Bool, false, "The task must not be marked as holding an unsent draft.")
        XCTAssertEqual(sentRecord["savedPrompt"] as? String, "Create a long history.", "The last sent prompt stays the saved prompt.")

        // A real draft typed on the same long conversation still survives reopening.
        composer.click()
        composer.typeText("Keep this draft.")
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["hasUnsentDraft"] as? Bool) == true
        }, timeout: 10), "The typed draft should be saved as an unsent draft.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: "Sent prompt past history page")
        XCTAssertTrue(waitUntil({
            (self.element("message-composer").value as? String) == "Keep this draft."
        }, timeout: 10), "Reopening should restore the real unsent draft.")
        attachScreenshot(named: "Real unsent draft restored after reopening past the history page")
        element("back-to-board-button").click()
    }
    // case-contract: test_conversation_history_pages_claude_transcript_from_store | Claude turns are stored row by row in the SQLite conversation store: a user image is kept out of the message text payload, and recording a later turn writes only that turn's own rows without rewriting earlier turns. CLI/XPC history stays complete by default; with --limit it reads only the stored turns covering the newest messages and returns those messages plus the count of earlier ones, and --before pages backward to the first message, with pages that join into the complete ordered history, carry its activities, and fill in the image only on the page that holds its message; this still holds after another turn completes. A non-positive or non-numeric limit fails with invalid_argument, an unknown --before message fails with not_found, and an empty conversation returns an empty page. Reopening the conversation in the visible UI reads only the newest page and pins the latest turn, scrolling straight down from that pin keeps the latest question near the top and the latest answer below it with no blank overscroll, and scrolling up then reads the older page from the store ahead of the reader, while loaded messages still remain above the rendered ones, until the first turn and its image are shown, and a turn sent afterwards from the composer keeps the earlier pages loaded without reading them again. A Claude conversation that never chose a model resolves it from its stored turns, in CLI/XPC reads and in the reopened composer’s picker: the newest assistant message that names a model, not an older turn’s model or the provider-wide remembered selection.
    func test_conversation_history_pages_claude_transcript_from_store() throws {
        try installClaudeFixtureExecutable(named: "claude-fixture-long-history")
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude paged history", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        let empty = try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "10"])["result"] as? [String: Any])
        XCTAssertEqual((empty["messages"] as? [Any])?.count, 0, "An empty conversation is an empty page.")
        XCTAssertEqual(empty["earlierMessageCount"] as? Int, 0)

        let image = dataDirectory.appendingPathComponent("first-turn.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let teal = NSColor(deviceRed: 0.1, green: 0.6, blue: 0.7, alpha: 1)
        for x in 0..<48 { for y in 0..<48 { bitmap.setColor(teal, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Long history turn 1.", "--image", image.path])
        let key = taskID.uppercased()
        let storedTurnsBefore = Set(try conversationRows("SELECT id FROM conversation_turns WHERE task_id = '\(key)'").map { $0[0] ?? "" })
        XCTAssertFalse(storedTurnsBefore.isEmpty, "The first Claude turn is stored as rows.")
        let imageRows = try conversationRows("SELECT payload, image_data_urls FROM conversation_messages WHERE task_id = '\(key)' AND image_data_urls IS NOT NULL")
        XCTAssertEqual(imageRows.count, 1, "The user image is stored once, in its own column.")
        let imagePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(imageRows.first?[0]).utf8)) as? [String: Any])
        XCTAssertEqual((imagePayload["imageDataURLs"] as? [Any])?.count, 0, "Image data stays out of the message text payload.")
        let storedImages = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(imageRows.first?[1]).utf8)) as? [String])
        XCTAssertTrue(storedImages.first?.hasPrefix("data:image/png;base64,") == true, "The image column holds the image data URL.")
        // Every later row write is logged, so the next turn proves it left earlier turns alone.
        try conversationExecute("""
            CREATE TABLE test_row_writes (kind TEXT NOT NULL, turn_id TEXT NOT NULL);
            CREATE TRIGGER test_message_insert AFTER INSERT ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', NEW.turn_id); END;
            CREATE TRIGGER test_message_update AFTER UPDATE ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', NEW.turn_id); END;
            CREATE TRIGGER test_message_delete AFTER DELETE ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', OLD.turn_id); END;
            CREATE TRIGGER test_activity_write AFTER UPDATE ON conversation_activities BEGIN INSERT INTO test_row_writes VALUES ('activity', NEW.turn_id); END;
            CREATE TRIGGER test_turn_write AFTER UPDATE ON conversation_turns BEGIN INSERT INTO test_row_writes VALUES ('turn', NEW.id); END;
            """)
        _ = try runCLI(["conversation", "send", taskID, "--message", "Long history turn 2."])
        let writes = try conversationRows("SELECT kind, turn_id FROM test_row_writes")
        try conversationExecute("""
            DROP TRIGGER test_message_insert; DROP TRIGGER test_message_update; DROP TRIGGER test_message_delete;
            DROP TRIGGER test_activity_write; DROP TRIGGER test_turn_write; DROP TABLE test_row_writes;
            """)
        XCTAssertGreaterThanOrEqual(writes.filter { $0[0] == "message" }.count, 31, "The second turn records its own messages.")
        XCTAssertTrue(writes.filter { storedTurnsBefore.contains($0[1] ?? "") }.isEmpty, "Recording a later turn must not rewrite any row of an earlier turn.")
        _ = try runCLI(["conversation", "send", taskID, "--message", "Long history turn 3."])
        _ = try runCLI(["conversation", "send", taskID, "--message", "Say hello."])

        let full = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        XCTAssertNil(full["earlierMessageCount"], "Default history is complete, not a page.")
        let allMessages = try XCTUnwrap(full["messages"] as? [[String: Any]])
        // The status nudges Playhouse sent are messages too, so the window counts include them.
        let messages = ordinaryMessages(allMessages)
        XCTAssertEqual(messages.count, 95)
        let total = allMessages.count
        XCTAssertEqual(total, 99)
        let latestStart = try XCTUnwrap(allMessages.lastIndex { ($0["role"] as? String) == "user" && !(($0["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:") })
        let latestWindow = total - latestStart
        XCTAssertEqual(messages.first?["text"] as? String, "Long history turn 1.")
        XCTAssertEqual(messages.last?["text"] as? String, "OK.")
        XCTAssertEqual((messages.first?["imageDataURLs"] as? [Any])?.count, 1, "Complete history includes the stored image.")
        func historyReads() throws -> [[String: Any]] {
            try diagnosticEvents().filter { $0["event"] as? String == "conversation.history.read" && $0["taskID"] as? String == key }
        }
        func readPages(matching full: [String: Any]) throws -> [[String: Any]] {
            let readsBefore = try historyReads().count
            var pages = [try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "40"])["result"] as? [String: Any])]
            while (pages[0]["earlierMessageCount"] as? Int ?? 0) > 0 {
                let before = try XCTUnwrap(((pages[0]["messages"] as? [[String: Any]])?.first)?["id"] as? String)
                pages.insert(try XCTUnwrap(try runCLI(["conversation", "history", taskID, "--limit", "40", "--before", before])["result"] as? [String: Any]), at: 0)
            }
            let fullMessages = try XCTUnwrap(full["messages"] as? [[String: Any]])
            let joined = pages.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(joined as NSArray, fullMessages as NSArray, "Pages join into the complete ordered history, images included.")
            for page in pages {
                XCTAssertEqual((page["activities"] as? [Any] ?? []) as NSArray, (full["activities"] as? [Any] ?? []) as NSArray,
                               "Every page carries the conversation's activities.")
                XCTAssertEqual((page["providerBoundaries"] as? [Any] ?? []) as NSArray, (full["providerBoundaries"] as? [Any] ?? []) as NSArray)
            }
            XCTAssertTrue(pages.dropFirst().allSatisfy { page in
                (page["messages"] as? [[String: Any]] ?? []).allSatisfy { ($0["imageDataURLs"] as? [Any])?.isEmpty ?? true }
            }, "Only the page holding the image message carries image data.")
            let reads = try historyReads().dropFirst(readsBefore)
            XCTAssertEqual(Set(reads.compactMap { $0["source"] as? String }), ["stored-page"],
                           "A Claude page is read from the stored turns it covers, not by composing the whole history.")
            XCTAssertEqual(reads.compactMap { $0["hydratedImageMessageCount"] as? String }, Array(repeating: "0", count: pages.count - 1) + ["1"])
            return pages
        }
        let pages = try readPages(matching: full)
        XCTAssertEqual(pages.map { ($0["messages"] as? [Any])?.count ?? -1 }, [19, 40, 40])
        XCTAssertEqual(pages.map { $0["earlierMessageCount"] as? Int ?? -1 }, [0, 19, 59])
        for limit in ["0", "-3", "many"] {
            assertCLIError(try runCLI(["conversation", "history", taskID, "--limit", limit], expectedStatus: 2), code: "invalid_argument")
        }
        assertCLIError(try runCLI(["conversation", "history", taskID, "--limit", "5", "--before", "no-such-message"], expectedStatus: 3), code: "not_found")

        let firstUserID = try XCTUnwrap(messages.first?["id"] as? String)
        let latestUserID = try XCTUnwrap(messages[messages.count - 2]["id"] as? String)
        let readsBeforeOpen = try historyReads().count
        openTask(named: "Claude paged history")
        let scrollView = element("conversation-scroll-view")
        let latestQuestion = element("user-message-\(latestUserID)")
        let oldest = element("user-message-\(firstUserID)")
        XCTAssertTrue(waitUntil({ scrollView.value as? String == "Showing latest \(latestWindow) of \(total) messages" }, timeout: 20),
                      "Reopening loads only the newest page and pins the latest turn.")
        XCTAssertTrue(waitUntil({ latestQuestion.exists && latestQuestion.isHittable }, timeout: 5), "The latest question is visible on open.")
        XCTAssertFalse(oldest.exists, "The first turn is not loaded with the newest page.")
        let openReads = try historyReads().dropFirst(readsBeforeOpen)
        XCTAssertTrue(openReads.contains {
            $0["messageLimit"] as? String == "80" && $0["returnedMessageCount"] as? String == "80"
                && $0["earlierMessageCount"] as? String == "\(total - 80)" && $0["source"] as? String == "stored-page"
        }, "Opening reads only the newest 80 messages from the stored turns.")
        XCTAssertFalse(openReads.contains { $0["returnedMessageCount"] as? String == "\(total)" }, "Opening never reads the whole conversation.")
        attachScreenshot(named: "Paged Claude history opens on the latest turn")
        // Scrolling straight down from the pinned turn must find its end, not blank space below it.
        assertTranscriptEndsWithoutOverscroll(question: latestQuestion, lastRow: try transcriptRow(for: XCTUnwrap(allMessages.last)), in: scrollView, turnFitsViewport: false)
        attachScreenshot(named: "Paged Claude history scrolled to the bottom")
        func isVisible(_ candidate: XCUIElement) -> Bool {
            candidate.exists && scrollView.frame.intersects(candidate.frame)
        }
        func scrollUp(until condition: () -> Bool) {
            for _ in 0..<40 {
                guard !condition() else { break }
                scrollView.scroll(byDeltaX: 0, deltaY: 400)
                _ = waitUntil(condition, timeout: 1)
            }
        }
        /// Once every message is loaded there is no page left to reveal on the way, so one long
        /// scroll reaches the first turn instead of dozens of 400-point steps.
        func scrollTowardFirstTurn() {
            scrollView.scroll(byDeltaX: 0, deltaY: 40_000)
        }
        func renderedCount() -> Int {
            (scrollView.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? 0
        }
        func olderPageWasRead(after readCount: Int) -> Bool {
            ((try? historyReads()) ?? []).dropFirst(readCount).contains {
                $0["beforeMessageProvided"] as? String == "true" && $0["returnedMessageCount"] as? String == "\(total - 80)"
                    && $0["earlierMessageCount"] as? String == "0" && $0["deferredImageMessageCount"] as? String == "1"
            }
        }
        let readsBeforeOlderPage = try historyReads().count
        scrollView.scroll(byDeltaX: 0, deltaY: 200)
        XCTAssertTrue(waitUntil({ renderedCount() > latestWindow }, timeout: 10), "Scrolling up reveals older messages already loaded.")
        XCTAssertFalse(olderPageWasRead(after: readsBeforeOlderPage), "The older page is not read while most of the loaded page is still unrevealed above the reader.")
        // The older page is read while loaded messages remain above the rendered window, so
        // the reader does not arrive at the oldest loaded message and wait there for it.
        scrollUp(until: { olderPageWasRead(after: readsBeforeOlderPage) })
        XCTAssertTrue(olderPageWasRead(after: readsBeforeOlderPage), "Scrolling toward the oldest loaded message reads the older page from the store, leaving its image to load when shown.")
        XCTAssertLessThan(renderedCount(), 80, "The older page is read before the reader runs out of loaded messages; rendered=\(renderedCount()).")
        attachScreenshot(named: "Older Claude page read from the store while scrolling up")
        scrollUp(until: { renderedCount() > 80 })
        XCTAssertGreaterThan(renderedCount(), 80, "Scrolling on reveals the messages of the older page.")
        revealWholeTranscript(step: 40_000, timeout: 90)
        XCTAssertEqual(scrollView.value as? String, "Showing latest \(total) of \(total) messages")
        scrollTowardFirstTurn()
        scrollUp(until: { isVisible(oldest) })
        XCTAssertTrue(waitUntil({ isVisible(oldest) }, timeout: 5), "Scrolling to the top shows the first turn.")
        let firstImage = element("chat-image-\(firstUserID)-0")
        XCTAssertTrue(firstImage.waitToExist(timeout: 5), "The first turn's image loads once its message is shown.")
        // The image renders above its message's text, so scroll until it is in view too.
        scrollUp(until: { isVisible(firstImage) })
        XCTAssertTrue(waitUntil({ isVisible(firstImage) }, timeout: 5), "The first turn's image is shown in the transcript.")
        let firstAnswer = element("assistant-message-\(try XCTUnwrap(messages[1]["id"] as? String))")
        XCTAssertTrue(waitUntil({ isVisible(firstAnswer) }, timeout: 5))
        XCTAssertLessThan(oldest.frame.minY, firstAnswer.frame.minY, "Older pages keep chronological order.")
        attachScreenshot(named: "First Claude turn and its image loaded from the store")

        // A turn sent from the composer keeps the earlier pages already loaded.
        let readsBeforeSend = try historyReads().count
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Say hello again.")
        element("send-message-button").click()
        func historyMessageCount() -> Int {
            ((try? self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])?.count ?? 0
        }
        XCTAssertTrue(waitUntil({ historyMessageCount() > total && self.noTurnIsRunning() }, timeout: 60), "The new turn and its status nudges should finish.")
        let grownTotal = historyMessageCount()
        XCTAssertTrue(waitUntil({ scrollView.value as? String == "Showing latest \(grownTotal) of \(grownTotal) messages" }, timeout: 30),
                      "The completed turn joins the transcript without dropping the earlier pages.")
        // Rows far above the viewport are not realized, so scroll back up to
        // confirm the first turn and its image are still loaded.
        scrollTowardFirstTurn()
        scrollUp(until: { isVisible(firstImage) })
        XCTAssertTrue(waitUntil({ isVisible(oldest) && isVisible(firstImage) }, timeout: 5),
                      "The first turn and its image stay loaded after the turn completes.")
        let sendReads = try historyReads().dropFirst(readsBeforeSend)
        XCTAssertFalse(sendReads.contains { $0["beforeMessageProvided"] as? String == "true" }, "Earlier pages are not read again.")
        XCTAssertTrue(sendReads.contains {
            $0["messageLimit"] as? String == "80" && $0["returnedMessageCount"] as? String == "80" && (Int($0["earlierMessageCount"] as? String ?? "") ?? 0) >= 17
        }, "The completed turn brings back only the newest page.")
        let grown = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let grownMessages = try XCTUnwrap(grown["messages"] as? [[String: Any]])
        let grownOrdinary = ordinaryMessages(grownMessages)
        XCTAssertEqual(grownOrdinary.count, 97)
        XCTAssertEqual(Array(grownOrdinary[..<95]) as NSArray, messages as NSArray, "A later turn does not change earlier messages.")
        XCTAssertEqual(try readPages(matching: grown).map { $0["earlierMessageCount"] as? Int ?? -1 }, [0, grownTotal - 80, grownTotal - 40])

        // A conversation that never chose a model resolves it from its stored turns: the newest
        // assistant message that names one, read without loading the whole conversation.
        returnToBoard()
        let modelTask = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Claude history model", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let modelTaskID = try XCTUnwrap(modelTask["id"] as? String)
        for _ in 0..<3 { _ = try runCLI(["conversation", "send", modelTaskID, "--message", "Say hello."]) }
        let modelKey = modelTaskID.uppercased()
        let modelTurnIDs = try conversationRows("SELECT id FROM conversation_turns WHERE task_id = '\(modelKey)' ORDER BY seq").compactMap { $0[0] }
        XCTAssertGreaterThanOrEqual(modelTurnIDs.count, 3)
        // The oldest turn ran on one model, the later ones on another, and the newest turn
        // predates recording a model at all.
        try conversationExecute("""
            UPDATE conversation_messages SET payload = json_set(payload, '$.modelID', 'claude-history-newer')
                WHERE task_id = '\(modelKey)' AND json_extract(payload, '$.role') = 'assistant';
            UPDATE conversation_messages SET payload = json_set(payload, '$.modelID', 'claude-history-older')
                WHERE task_id = '\(modelKey)' AND turn_id = '\(try XCTUnwrap(modelTurnIDs.first))' AND json_extract(payload, '$.role') = 'assistant';
            UPDATE conversation_messages SET payload = json_remove(payload, '$.modelID')
                WHERE task_id = '\(modelKey)' AND turn_id = '\(try XCTUnwrap(modelTurnIDs.last))';
            """)
        // The provider-wide remembered selection moves elsewhere; the conversation keeps its own.
        _ = try runCLI(["conversation", "model", taskID, "set", "claude-preference-choice"])
        for _ in 0..<2 {
            XCTAssertEqual((try runCLI(["conversation", "model", modelTaskID])["result"] as? [String: Any])?["modelID"] as? String, "claude-history-newer",
                           "The model comes from the newest stored assistant message that names one, not the oldest turn or the remembered selection.")
        }
        openTask(named: "Claude history model")
        let historyModelPicker = element("model-picker-menu")
        XCTAssertTrue(waitUntil({ historyModelPicker.exists && historyModelPicker.label.contains("claude-history-newer") }, timeout: 10),
                      "Opening the conversation shows the model its stored turns last ran on.")
        attachElementScreenshot(historyModelPicker, named: "Model resolved from the conversation's stored turns")
    }
    // case-contract: test_conversation_shows_subagent_delegation | During a parent turn, Working for renders open and active agents appear as individual named rows, each with an arrow that opens it, outside it, with available path/model/reasoning metadata and started-working wording; a mid-turn collapse the reader performs is honored. When the final answer arrives, all agent rows collapse inside Worked for alongside other Codex activity; expanding it reveals clickable agent rows. The UI fixture pauses after the final answer to verify this before turn completion while Stop response remains available. Completed, interrupted, and unknown states survive history reload and remain inspectable after reopening. The child thread opens as read-only through thread/read, thread/turns/list, and thread/items/list without editable controls or thread/resume, and diagnostics retain safe RPC outcomes while excluding conversation text, command output, and diffs. Multiple Codex message deltas and command-output deltas are summarized per item with counts and byte totals, flushed at turn completion, and excluded from individual notification records; lifecycle notifications remain individually logged, and diagnostics exclude conversation text, command output, and diffs. A fresh `conversation subagent-history` read returns the completed child's stored conversation content.
    func test_conversation_shows_subagent_delegation() throws {
        let fixtureRoot = WorkspaceFixture.root
        let fixtureOwnerMarker = fixtureRoot.appendingPathComponent(".playhouse-bridge-fixture")
        XCTAssertEqual(
            try String(contentsOf: fixtureOwnerMarker, encoding: .utf8),
            "Playhouse bridge tests own this deterministic fixture (v1).\n",
            "Refusing to place the Codex fixture in a directory Playhouse does not own."
        )
        let fixtureCopy = fixtureRoot.appendingPathComponent("codex-fixture-subagent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the subagent fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        let finalAnswerPause = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-pause")
        let finalAnswerReady = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-ready")
        let finalAnswerRelease = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-release")
        try? FileManager.default.removeItem(at: finalAnswerReady)
        try? FileManager.default.removeItem(at: finalAnswerRelease)
        try "Pause final answer until the UI checks the collapsed disclosure.\n".write(to: finalAnswerPause, atomically: true, encoding: .utf8)
        defer {
            try? "Release the final answer fixture.\n".write(to: finalAnswerRelease, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: finalAnswerPause)
        }
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Subagent delegation", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Subagent delegation")
        openTask(named: "Subagent delegation")
        let prompt = "Delegate this task."
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText(prompt)
        element("send-message-button").click()

        let subagentReady = URL(fileURLWithPath: fixtureCopy.path + ".subagent-ready")
        let subagentRelease = URL(fileURLWithPath: fixtureCopy.path + ".subagent-release")
        defer { try? "Release active child fixture.\n".write(to: subagentRelease, atomically: true, encoding: .utf8) }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: subagentReady.path) }, timeout: 20), "The fixture should expose the active child interval before completion.")
        let activityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(activityDisclosure.waitToExist(timeout: 10), "Active child work should appear in conversation activity.")
        // Every activity in flight here renders outside the section, so the open
        // section has nothing inside it yet; its state is the chevron, not content.
        XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Expanded, down chevron" }, timeout: 10),
                      "A turn in flight should show its work instead of hiding it behind Working for.")
        let activeChildButton = element("codex-subagent-row-00000000-0000-0000-0000-000000000002")
        XCTAssertTrue(activeChildButton.waitToExist(timeout: 10), "The running child should appear as a clickable timeline row beside the open Codex activity.")
        XCTAssertEqual(activityDisclosure.descendants(matching: .any).matching(identifier: "codex-subagent-row-00000000-0000-0000-0000-000000000002").count, 0,
                       "Active agents should not be nested inside Working for.")
        XCTAssertTrue(activeChildButton.label.contains("Sandbox review"))
        XCTAssertTrue(activeChildButton.label.contains("started working"))
        let agentIcon = activeChildButton.images.matching(NSPredicate(format: "label == %@", "Sandbox review agent icon")).firstMatch
        XCTAssertTrue(agentIcon.waitToExist(timeout: 5), "The requested robot icon should render in the child timeline row.")
        assertSubagentIconArtwork(agentIcon)
        let secondActiveChildButton = element("codex-subagent-row-00000000-0000-0000-0000-000000000003")
        XCTAssertTrue(secondActiveChildButton.waitToExist(timeout: 5),
                      "Every active agent should remain visible outside the Codex activity section.")
        // The open section is a default, not a lock: folding it mid-turn sticks.
        activityDisclosure.click()
        XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Collapsed, right chevron" }, timeout: 5),
                      "A reader should still be able to fold the open section while the turn runs.")
        // Folding the section is what proves the active agents render outside it.
        XCTAssertTrue(activeChildButton.exists && secondActiveChildButton.exists,
                      "Active agents render outside the section, so folding it must not hide them.")
        activityDisclosure.click()
        XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Expanded, down chevron" }, timeout: 5),
                      "Reopening the section mid-turn should restore the open chevron.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-subagent-row-00000000-0000-0000-0000-000000000002").count, 1,
                       "The interacted update should update the single timeline row instead of creating a duplicate.")
        let childMetadata = subagentRowMetadata(activeChildButton)
        XCTAssertTrue(childMetadata.contains("/agents/Sandbox review"))
        XCTAssertTrue(childMetadata.contains("gpt-6-sol"))
        XCTAssertTrue(childMetadata.contains("high"))
        XCTAssertTrue(secondActiveChildButton.waitToExist(timeout: 5))
        XCTAssertTrue(secondActiveChildButton.label.contains("Some agent"), "Underscored agent names should render with spaces and sentence capitalization.")
        XCTAssertTrue(secondActiveChildButton.label.contains("started working"))
        let secondChildMetadata = subagentRowMetadata(secondActiveChildButton)
        XCTAssertTrue(secondChildMetadata.contains("/agents/some_agent"))
        XCTAssertFalse(secondChildMetadata.contains("gpt-"), "Optional child model metadata may be absent.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "subagent-row-chevron", "Some agent"
        )).firstMatch.exists, "Each agent row should show an arrow that opens it.")
        activeChildButton.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitToExist(timeout: 5))
        try "Release child to finish and answer read-only inspection requests.\n".write(to: subagentRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("subagent-back-button").exists)
        XCTAssertTrue(app.staticTexts["Read only"].exists)
        XCTAssertFalse(element("message-composer").exists, "The child conversation must not expose the parent composer.")
        XCTAssertFalse(element("send-message-button").exists, "The child conversation must not expose a send action.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("found the required profile") }, timeout: 20), "The child view should render its stored conversation content.")
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5), "Back should return to the parent conversation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: finalAnswerReady.path) }, timeout: 20),
                      "The fixture should pause after the final answer appears but before the turn completes.")
        XCTAssertTrue(waitUntil({
            activityDisclosure.label.contains("Worked for")
                && activityDisclosure.value as? String == "Collapsed, right chevron"
                && self.transcriptContains("The subagent inspected the project structure")
        }, timeout: 10), "The final answer should immediately produce a clean collapsed Worked for section.")
        XCTAssertEqual(element("pause-response-button").label, "Stop response",
                       "The final-answer transition should be checked while the turn is still responding.")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should move inside Worked for as soon as the final answer arrives.")
        }
        try "Allow the parent turn to complete.\n".write(to: finalAnswerRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 20), "The visible composer turn should finish and persist the task status.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "codex.rpc.response.succeeded" && $0["method"] as? String == "turn/start"
            }) == true
        }, timeout: 5), "Codex diagnostics should be flushed before checking turn and notification details.")
        let codexDiagnostics = try diagnosticEvents()
        let deltaSummaries = codexDiagnostics.filter { $0["event"] as? String == "codex.notification.summary" }
        XCTAssertFalse(deltaSummaries.isEmpty, "Streamed Codex deltas should be summarized rather than logged individually.")
        let messageSummary = try XCTUnwrap(deltaSummaries.first { $0["method"] as? String == "item/agentMessage/delta" })
        XCTAssertGreaterThanOrEqual(Int(messageSummary["notificationCount"] as? String ?? "0") ?? 0, 2)
        XCTAssertGreaterThan(Int(messageSummary["payloadBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertEqual(messageSummary["flushReason"] as? String, "turn_completed")
        let outputSummary = try XCTUnwrap(deltaSummaries.first { $0["method"] as? String == "item/commandExecution/outputDelta" })
        XCTAssertEqual(Int(outputSummary["notificationCount"] as? String ?? "0") ?? 0, 2)
        XCTAssertGreaterThan(Int(outputSummary["payloadBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertEqual(outputSummary["flushReason"] as? String, "turn_completed")
        XCTAssertFalse(codexDiagnostics.contains {
            $0["event"] as? String == "codex.notification"
                && ["item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"].contains($0["method"] as? String ?? "")
        }, "High-volume delta notifications should not each occupy a diagnostics record.")
        XCTAssertTrue(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.request.started" && $0["method"] as? String == "turn/start"
        })
        XCTAssertTrue(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.response.succeeded" && $0["method"] as? String == "turn/start"
        })
        let commandDiagnostic = try XCTUnwrap(codexDiagnostics.first {
            $0["event"] as? String == "codex.notification"
                && $0["method"] as? String == "item/completed"
                && $0["itemType"] as? String == "commandExecution"
        })
        XCTAssertEqual(commandDiagnostic["command"] as? String, "git status --short")
        let loggedWorkingDirectory = try XCTUnwrap(commandDiagnostic["workingDirectory"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: loggedWorkingDirectory).resolvingSymlinksInPath().standardizedFileURL.path,
                       fixture.primary.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertGreaterThan(Int(commandDiagnostic["outputBytes"] as? String ?? "0") ?? 0, 0)
        let fileDiagnostic = try XCTUnwrap(codexDiagnostics.first {
            $0["event"] as? String == "codex.notification"
                && $0["method"] as? String == "item/completed"
                && $0["itemType"] as? String == "fileChange"
        })
        XCTAssertEqual(fileDiagnostic["changedPathCount"] as? String, "1")
        XCTAssertEqual(fileDiagnostic["changedPaths"] as? String, "README.md")
        XCTAssertEqual(fileDiagnostic["changeKinds"] as? String, "update")
        let serializedCodexDiagnostics = String(data: try JSONSerialization.data(withJSONObject: codexDiagnostics), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_OUTPUT_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_DIFF_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_STREAMED_OUTPUT_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains(prompt), "Diagnostics must not store the conversation text.")

        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Playhouse must be foreground before inspecting the conversation.")

        XCTAssertTrue(activityDisclosure.waitToExist(timeout: 20), "A delegated task should appear in conversation activity.")
        XCTAssertTrue(activityDisclosure.label.contains("Worked for"), "The completed turn should use the Worked for disclosure.")
        XCTAssertEqual(activityDisclosure.value as? String, "Collapsed, right chevron",
                       "The final answer should arrive with all Codex activity collapsed.")
        XCTAssertTrue(transcriptContains("The subagent inspected the project structure"),
                      "The final answer should remain visible while agent details are collapsed.")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should be hidden inside the collapsed Worked for disclosure.")
        }
        activityDisclosure.click()
        let activityRow = element("codex-activity-row-item_playhouse_subagent")
        XCTAssertTrue(activityRow.waitToExist(timeout: 10))
        XCTAssertTrue(activityRow.label.contains("Task delegated to subagent"))
        XCTAssertTrue(activityRow.label.contains("Completed"))
        XCTAssertTrue(app.staticTexts["Agents used"].exists)
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000002").label.contains("finished working"))
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000003").label.contains("was interrupted"))
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000004").exists, "An unknown child kind should remain inspectable.")
        let activityDetail = element("codex-activity-detail-item_playhouse_subagent")
        XCTAssertTrue(activityDetail.waitToExist(timeout: 5))
        let detailDescription = "\(activityDetail.label) \(activityDetail.value as? String ?? "")"
        XCTAssertTrue(detailDescription.contains("Inspect the project structure and report relevant files."))
        let childThreadID = "00000000-0000-0000-0000-000000000002"
        for method in ["thread/read", "thread/turns/list", "thread/items/list"] {
            XCTAssertTrue(codexDiagnostics.contains {
                $0["event"] as? String == "codex.rpc.request.started"
                    && $0["method"] as? String == method
                    && $0["parameter.threadId"] as? String == childThreadID
            }, "Child inspection should call \(method) for the child thread.")
        }
        XCTAssertFalse(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.request.started"
                && $0["method"] as? String == "thread/resume"
                && $0["parameter.threadId"] as? String == childThreadID
        }, "Inspecting a child thread must not resume it.")

        let completedChildRow = element("codex-subagent-row-00000000-0000-0000-0000-000000000002")
        let transcriptScrollView = element("conversation-scroll-view")
        for _ in 0..<8 {
            guard !transcriptScrollView.frame.contains(completedChildRow.frame) else { break }
            transcriptScrollView.scroll(byDeltaX: 0, deltaY: -150)
        }
        completedChildRow.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitToExist(timeout: 5),
                      "An expanded finished agent row should open its conversation.")
        XCTAssertTrue(app.staticTexts["Read only"].exists)
        XCTAssertFalse(element("message-composer").exists)
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5))

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10), "The task should close before checking its saved conversation history.")
        openTask(named: "Subagent delegation")
        XCTAssertTrue(activityDisclosure.waitToExist(timeout: 10))
        XCTAssertTrue(activityDisclosure.label.contains("Worked for"), "The reopened final answer should retain the Worked for disclosure.")
        XCTAssertEqual(activityDisclosure.value as? String, "Collapsed, right chevron")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should remain collapsed inside Worked for after reopening.")
        }
        activityDisclosure.click()
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000002").label.contains("finished working"), "The completed child should remain inspectable after reopening the task.")
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000003").label.contains("was interrupted"), "The interrupted child should remain inspectable after reopening the task.")
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000004").exists, "The unknown child kind should remain inspectable after reopening the task.")
        let reopenedHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let sandboxActivity = try XCTUnwrap((reopenedHistory["activities"] as? [[String: Any]])?.first {
            $0["childThreadID"] as? String == "00000000-0000-0000-0000-000000000002"
        })
        let sandboxActivityJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: sandboxActivity), encoding: .utf8))
        let inspected = try XCTUnwrap(try runCLI(["conversation", "subagent-history", taskID, "--activity", sandboxActivityJSON])["result"] as? [String: Any])
        XCTAssertTrue((inspected["messages"] as? [[String: Any]] ?? []).contains {
            ($0["text"] as? String)?.contains("found the required profile") == true
        }, "A fresh read-only subagent inspection should return the child conversation's stored content.")
        attachScreenshot(named: "Conversation shows and opens a subagent")
    }
}

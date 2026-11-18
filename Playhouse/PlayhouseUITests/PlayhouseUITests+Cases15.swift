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
    // case-contract: test_conversation_persists_unsent_comments | Unsent conversation comments are saved with the task draft. Through CLI/XPC, a saved comment list reports its count on a fresh read, malformed input is rejected with invalid_argument and leaves the saved comments unchanged, a later draft save keeps them, appending a list adds only comments not already saved (how a send that ends without delivering its comments returns them without overwriting newer ones), and an empty list clears them, as the composer chip's Discard comments badge does. Saving comments after a sent prompt leaves hasUnsentDraft false, so the sent prompt never returns to the composer as a draft. In the app, comments added to a conversation through the selection pill's Comment popover are saved as they are added and survive switching to another task and back and quitting and relaunching: the composer shows the pending comment count and the highlights are restored. Sending them delivers their source ranges, clears the saved comments, and reopening the task shows no pending comment and no duplicate. Once sent, a comment can no longer be edited (task comments edit reports not_found), and clicking its text reopens it read-only in the comment popover, whose field can still add a new comment there. The comment chip's X badge (Discard comments) discards every unsent comment at once: the chip and their highlights go, the sent comment stays, and pendingCommentCount is 0 on a fresh read.
    func test_conversation_persists_unsent_comments() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-goal-success").path
        let fixtureStateDirectory = dataDirectory.appendingPathComponent("unsent-comments-fixture-state", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureStateDirectory, withIntermediateDirectories: true)
        codexFixtureStateDirectory = fixtureStateDirectory
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Unsent comments", roots: [fixture.primary.path])
        try createTaskFixture(title: "Other task", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Unsent comments")
        let sourceText = "Comment on these words in a user message."
        _ = try runCLI(["conversation", "send", taskID, "--message", sourceText])
        // The fixture turn and its outcome nudge settle before the message ids are read.
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 60), "The source turn should finish before it is commented on.")
        openTask(named: "Unsent comments")
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let messages = try XCTUnwrap(history?["messages"] as? [[String: Any]])
        // The reply sits below the top of the transcript, so the selection pill above it stays clickable.
        // The latest turn's final answer: the transcript opens on that turn, so an earlier turn's reply
        // may not be rendered, and commentary folds into the collapsed Worked for once the turn ends.
        let sourceMessage = try XCTUnwrap(ordinaryMessages(messages).last {
            $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" && !($0["text"] as? String ?? "").isEmpty
        })
        let sourceID = try XCTUnwrap(sourceMessage["id"] as? String)
        // Looked up on each use: the relaunch below replaces the app instance.
        var sourceView: XCUIElement { element("assistant-message-\(sourceID)").descendants(matching: .staticText).firstMatch }
        XCTAssertTrue(sourceView.waitToExist(timeout: 10))
        XCTAssertTrue(waitForStableFrame(sourceView), "The source message should settle before it is measured.")
        let orangeBefore = orangePixelCount(in: sourceView.screenshot())
        let selectedText = (sourceView.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(selectedText.isEmpty, "The reply should expose its selectable text.")
        sourceView.click()
        sourceView.typeKey("a", modifierFlags: .command)
        addCommentFromSelection("Keep this unsent comment")
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["pendingCommentCount"] as? Int) == 1
        }, timeout: 10), "An added comment should be saved with the task draft.")
        XCTAssertEqual(try taskRecord(id: taskID)?["hasUnsentDraft"] as? Bool, false,
                       "A comment must not turn the last sent prompt into a draft.")
        attachScreenshot(named: "Unsent comment added")

        func assertCommentRestored(_ context: String) {
            XCTAssertTrue(sourceView.waitToExist(timeout: 10), "The source message should render \(context).")
            XCTAssertTrue(waitUntil({
                self.accessibleLabelOrValue(of: self.element("pending-comment-count")).contains("1 comment")
            }, timeout: 10), "The composer should show the restored pending comment \(context).")
            XCTAssertTrue(waitForStableFrame(sourceView))
            XCTAssertGreaterThan(orangePixelCount(in: sourceView.screenshot()), orangeBefore + 5,
                                 "The restored comment should highlight its text \(context).")
            XCTAssertTrue(element("send-message-button").isEnabled, "A restored comment should be sendable \(context).")
            XCTAssertTrue((app.textViews["message-composer"].value as? String ?? "").isEmpty,
                          "The sent prompt must not return to the composer \(context).")
        }

        element("back-to-board-button").click()
        openTask(named: "Other task")
        XCTAssertFalse(element("pending-comment-count").waitToExist(timeout: 2), "Another task should not show these comments.")
        element("back-to-board-button").click()
        openTask(named: "Unsent comments")
        assertCommentRestored("after switching tasks")
        attachScreenshot(named: "Unsent comment restored after switching tasks")

        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Unsent comments")
        assertCommentRestored("after relaunching")
        attachScreenshot(named: "Unsent comment restored after relaunch")

        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response",
                  let history = try? self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any],
                  let messages = history["messages"] as? [[String: Any]] else { return false }
            return self.ordinaryMessages(messages).contains {
                ($0["role"] as? String) == "user" && ($0["text"] as? String ?? "").contains("Keep this unsent comment")
            }
        }, timeout: 60), "The restored comment should be sent and its turn should finish.")
        let sentHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let sentMessages = try XCTUnwrap(sentHistory["messages"] as? [[String: Any]])
        let sentPrompt = try XCTUnwrap(ordinaryMessages(sentMessages).last(where: { ($0["role"] as? String) == "user" })?["text"] as? String)
        XCTAssertTrue(sentPrompt.contains("\"messageId\":\"\(sourceID)\""), "The restored comment should keep its source message.")
        XCTAssertTrue(sentPrompt.contains("\"startOffset\":0") && sentPrompt.contains("\"text\":\"\(selectedText.prefix { $0 != "/" })"),
                      "The restored comment should keep its source range and quoted text.")
        XCTAssertEqual(sentPrompt.components(separatedBy: "Keep this unsent comment").count - 1, 1, "The comment should be sent once.")
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["pendingCommentCount"] as? Int) == 0
        }, timeout: 10), "Sending should clear the saved comments.")
        XCTAssertFalse(element("pending-comment-count").exists, "No pending comment should remain after sending.")
        // The sent comment stays orange; clicking it reopens it read-only in the comment popover,
        // whose field still adds a new comment.
        XCTAssertTrue(sourceView.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertTrue(waitForStableFrame(sourceView))
        func openSentCommentPopover() -> XCUIElement {
            clickHighlightedText(sourceView)
            let popover = element("comment-popover")
            XCTAssertTrue(popover.waitToExist(timeout: 8), "Clicking a sent comment's text should open its comment popover.")
            XCTAssertFalse(element("side-chat-bubble").exists, "Text with only a comment opens no side chat bubble.")
            return popover
        }
        let sentPopover = openSentCommentPopover()
        let sentComment = element("sent-comment-text")
        XCTAssertTrue(sentComment.waitToExist(timeout: 5), "A sent comment should show in the reopened popover.")
        XCTAssertTrue(accessibleLabelOrValue(of: sentComment).contains("Keep this unsent comment"))
        let sentField = element("comment-input-field")
        XCTAssertTrue(sentField.waitToExist(timeout: 5), "Another comment can still be added on a sent comment's text.")
        XCTAssertEqual(sentField.placeholderValue, "Add an optional comment…", "The field beside a sent comment adds a new one.")
        XCTAssertFalse(accessibleLabelOrValue(of: sentField).contains("Keep this unsent comment"), "A sent comment can't be edited.")
        XCTAssertEqual(element("add-comment-button").label, "Add comment")
        XCTAssertFalse(element("discard-comment-button").exists, "A sent comment can't be discarded.")
        attachElementScreenshot(sentPopover, named: "Sent comment reopened read-only in the comment popover")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sentPopover.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("pending-comment-count").exists, "Reopening a sent comment adds no pending comment.")

        // A new comment on the sent text and one on the latest reply are discarded together by the
        // X badge on the composer's comment chip.
        _ = openSentCommentPopover()
        sentField.click()
        sentField.typeText("A second look")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("comment-popover").waitForNonExistence(timeout: 5), "Return should add the new comment.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["pendingCommentCount"] as? Int) == 1 }, timeout: 10),
                      "A comment added beside a sent one should be saved as unsent.")
        let latestHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        // The reply to the send that carried the comment: later recovery turns may add replies
        // that aren't rendered as ordinary assistant messages.
        let latestMessages = try XCTUnwrap(latestHistory["messages"] as? [[String: Any]])
        let commentSendIndex = try XCTUnwrap(latestMessages.lastIndex {
            $0["role"] as? String == "user" && ($0["text"] as? String ?? "").contains("<response-comments>")
        }, "The sent comment should be in the history.")
        let latestReply = try XCTUnwrap(latestMessages[(commentSendIndex + 1)...].first {
            $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer"
                && !($0["text"] as? String ?? "").isEmpty
        }, "The comment send should produce a new reply.")
        let latestReplyView = element("assistant-message-\(try XCTUnwrap(latestReply["id"] as? String))")
            .descendants(matching: .staticText).firstMatch
        // The reply may sit outside the visible transcript, above a later reply to Playhouse's
        // outcome reminder or below, where clicking it would select nothing.
        XCTAssertTrue(latestReplyView.waitToExist(timeout: 10))
        XCTAssertTrue(scrollFullyIntoView(latestReplyView, in: element("conversation-scroll-view")),
                      "The latest reply should scroll into view.")
        XCTAssertTrue(waitForStableFrame(latestReplyView))
        let latestOrangeBefore = orangePixelCount(in: latestReplyView.screenshot())
        latestReplyView.click()
        latestReplyView.typeKey("a", modifierFlags: .command)
        addCommentFromSelection("And this reply")
        let chip = element("pending-comment-count")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: chip).contains("2 comments") }, timeout: 10),
                      "The composer should count both unsent comments.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["pendingCommentCount"] as? Int) == 2 }, timeout: 10))
        XCTAssertTrue(waitUntil({ self.orangePixelCount(in: latestReplyView.screenshot()) > latestOrangeBefore + 5 }, timeout: 5),
                      "The new comment should highlight the latest reply.")
        let discardAll = element("discard-pending-comments-button")
        XCTAssertTrue(discardAll.waitToExist(timeout: 5), "The comment chip should carry an X badge.")
        XCTAssertEqual(discardAll.label, "Discard comments")
        attachScreenshot(named: "Comment chip with its Discard comments badge")
        attachElementScreenshot(chip, named: "Two unsent comments in the composer chip")
        discardAll.click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "Discarding all comments should remove the chip.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["pendingCommentCount"] as? Int) == 0 }, timeout: 10),
                      "Discarding all comments should clear the saved comments.")
        XCTAssertTrue(waitUntil({ self.orangePixelCount(in: latestReplyView.screenshot()) <= latestOrangeBefore + 5 }, timeout: 5),
                      "A discarded comment's highlight should go.")
        XCTAssertFalse(element("send-message-button").isEnabled, "No comment is left to send.")
        attachScreenshot(named: "Unsent comments discarded from the chip badge")
        // The sent comment is not unsent, so it stays.
        _ = openSentCommentPopover()
        XCTAssertTrue(element("sent-comment-text").waitToExist(timeout: 5), "Discarding unsent comments keeps the sent one.")
        XCTAssertFalse(element("discard-comment-button").exists, "The discarded unsent comment should not reopen.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("comment-popover").waitForNonExistence(timeout: 5))

        element("back-to-board-button").click()
        openTask(named: "Unsent comments")
        XCTAssertTrue(sourceView.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertFalse(element("pending-comment-count").waitToExist(timeout: 3),
                       "Reopening after the send should show no stale pending comment.")
        XCTAssertEqual(try taskRecord(id: taskID)?["pendingCommentCount"] as? Int, 0)
        attachScreenshot(named: "Sent comment reopened without a pending duplicate")
    }
    // case-contract: test_side_chat_and_comment_reopen_from_highlighted_text | Clicking commented or side-chatted conversation text, without selecting any, reopens what it holds: text with only a comment opens its comment popover, text with only a side chat opens its side chat bubble, and text with both shows the Comment and Side chat pill to choose between them. A side chat opened on a selection is saved on the task with its source range, selected text, provider conversation, model and every answered exchange; closing its bubble keeps it, its text renders purple while no comment covers it and orange once a comment does, and reopening it shows its history and continues the same forked conversation, so its next answer is saved after the earlier ones. A comment is added on side-chatted text by selecting it and choosing the pill's Comment. An unsent comment opens in the comment popover prefilled to edit, with a Save comment button that stays disabled until the text changes and a Discard comment button: saving changed text keeps the comment with the new text, Escape closes it unchanged, Discard deletes only that comment, leaving the side chat and its purple text, and saving it emptied deletes it. Through CLI/XPC, conversation side-chats lists the saved side chats, a side chat's source must name a message and a non-empty range, task comments edit changes an unsent comment's text, empty text deletes it (as Discard does) leaving the other comments, and an unknown comment is not_found. Edits and side chats survive a fresh read and relaunching the app.
    func test_side_chat_and_comment_reopen_from_highlighted_text() throws {
        _ = try installClaudeFixture(named: "claude-fixture-side-chat")
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        launchApp(defaultParent: fixture.parent.path)
        let title = "Reopen side chat"
        let opened = try openSideChatOnReply(title: title)
        let history = try XCTUnwrap(try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])
        let replyID = try XCTUnwrap(ordinaryMessages(try XCTUnwrap(history["messages"] as? [[String: Any]]))
            .last { ($0["role"] as? String) == "assistant" }?["id"] as? String)
        // Looked up on each use: the relaunch below replaces the app instance.
        var reply: XCUIElement { element("assistant-message-\(replyID)").descendants(matching: .staticText).firstMatch }
        var bubble: XCUIElement { element("side-chat-bubble") }
        let orangeBefore = orangePixelCount(in: reply.screenshot())
        let purpleBefore = purplePixelCount(in: reply.screenshot())
        func savedSideChats() throws -> [[String: Any]] {
            try XCTUnwrap(try runCLI(["conversation", "side-chats", opened.taskID])["result"] as? [[String: Any]])
        }

        _ = sendSideChatMessage("What does this mean?", answerIndex: 1, containing: "Side chat about")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Escape should close the side chat bubble.")
        XCTAssertTrue(waitUntil({ self.purplePixelCount(in: reply.screenshot()) > purpleBefore + 5 }, timeout: 5),
                      "With its bubble closed, a side chat without a comment should color its text purple.")
        let saved = try XCTUnwrap(try savedSideChats().first, "Closing the bubble should keep its side chat saved.")
        XCTAssertEqual((saved["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((saved["source"] as? [String: Any])?["messageID"] as? String, replyID, "The side chat should save where its text is.")

        // The side chat's text is purple, and clicking it, with only a side chat, reopens the bubble
        // with its history and no comment UI.
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking text with only a side chat should reopen its bubble.")
        XCTAssertFalse(element("comment-popover").exists, "Text with only a side chat opens no comment popover.")
        XCTAssertGreaterThan(purplePixelCount(in: reply.screenshot()), purpleBefore + 5, "A side chat without a comment should color its text purple.")
        XCTAssertLessThan(orangePixelCount(in: reply.screenshot()), orangeBefore + 5, "Side-chatted text without a comment is not orange.")
        XCTAssertEqual(element("side-chat-user-message-0").label, "What does this mean?", "The reopened bubble should show the saved question.")
        XCTAssertTrue(element("side-chat-assistant-message-1").label.contains("Side chat about"), "The reopened bubble should show the saved answer.")
        XCTAssertFalse(bubble.descendants(matching: .any).matching(identifier: "add-comment-button").firstMatch.exists,
                       "The side chat bubble has no comment UI.")
        attachScreenshot(named: "Side chat reopened from its purple text")
        _ = sendSideChatMessage("And then?", answerIndex: 3, containing: "Side chat follow-up 2 on")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))

        // Selecting the same text by dragging across it (a click would reopen the bubble) shows the
        // pill, whose Comment adds a comment on the side-chatted text, turning it orange.
        XCTAssertTrue(waitForStableFrame(reply))
        reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: 10))
            .press(forDuration: 0.3, thenDragTo: reply.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -1, dy: -3)))
        addCommentFromSelection("Explain the parser here")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 1 }, timeout: 10))
        XCTAssertTrue(waitUntil({ self.orangePixelCount(in: reply.screenshot()) > orangeBefore + 5 }, timeout: 5),
                      "Text with both a comment and a side chat should be orange.")
        XCTAssertLessThan(purplePixelCount(in: reply.screenshot()), purpleBefore + 5, "The comment's orange should cover the side chat's purple.")
        attachElementScreenshot(reply, named: "Commented side chat text renders orange")

        // Text holding both shows the pill on click; its Comment opens the unsent comment to edit.
        func clickBothAndChoose(_ choice: String, context: String) {
            clickHighlightedText(reply)
            let pill = waitForSelectionActionsPill()
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertFalse(bubble.exists, "Text with a comment and a side chat opens nothing until a pill action is chosen \(context).")
            XCTAssertFalse(element("comment-popover").exists, "Text with a comment and a side chat opens nothing until a pill action is chosen \(context).")
            (choice == "Comment" ? pill.comment : pill.sideChat).click()
        }
        clickHighlightedText(reply)
        _ = waitForSelectionActionsPill()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(bubble.exists, "Text with a comment and a side chat shows the pill instead of the bubble.")
        XCTAssertFalse(element("comment-popover").exists, "Text with a comment and a side chat shows the pill instead of the popover.")
        attachScreenshot(named: "Comment and Side chat pill on text holding both")
        waitForSelectionActionsPill().comment.click()
        let popover = element("comment-popover")
        let commentField = element("comment-input-field")
        let saveComment = element("add-comment-button")
        XCTAssertTrue(popover.waitToExist(timeout: 8), "The pill's Comment should open the comment popover.")
        XCTAssertTrue(commentField.waitToExist(timeout: 5))
        XCTAssertEqual(commentField.value as? String, "Explain the parser here", "The unsent comment should open prefilled to edit.")
        XCTAssertEqual(commentField.placeholderValue, "Empty, saving deletes the comment")
        XCTAssertEqual(saveComment.label, "Save comment")
        XCTAssertFalse(saveComment.isEnabled, "An unchanged comment has nothing to save.")
        let discardComment = element("discard-comment-button")
        XCTAssertTrue(discardComment.exists, "An unsent comment can be discarded from its popover.")
        XCTAssertEqual(discardComment.label, "Discard comment")
        XCTAssertFalse(element("sent-comment-text").exists, "An unsent comment is not shown as sent.")
        attachElementScreenshot(popover, named: "Unsent comment reopened to edit with Save and Discard")
        commentField.click()
        commentField.typeKey("a", modifierFlags: .command)
        commentField.typeText("Explain it again")
        XCTAssertTrue(saveComment.isEnabled, "A changed comment can be saved.")
        attachElementScreenshot(popover, named: "Comment edited in the comment popover")
        saveComment.click()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Saving the comment should close the popover.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("pending-comment-count")).contains("1 comment"), "Editing keeps the one comment.")
        // The pill's Side chat opens the bubble with the side chat's history and no comment UI.
        clickBothAndChoose("Side chat", context: "before choosing Side chat")
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "The pill's Side chat should reopen the bubble.")
        XCTAssertTrue(element("side-chat-assistant-message-3").label.contains("Side chat follow-up 2 on"), "The side chat history should reopen.")
        XCTAssertFalse(bubble.descendants(matching: .any).matching(identifier: "add-comment-button").firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))

        // The edit and the side chat survive relaunching.
        Thread.sleep(forTimeInterval: 1)
        relaunchApp()
        openTask(named: title)
        XCTAssertTrue(reply.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertTrue(waitForStableFrame(reply))
        // The saved side chats load beside the transcript; the pill opens with what is loaded.
        Thread.sleep(forTimeInterval: 1)
        clickBothAndChoose("Comment", context: "after relaunching")
        XCTAssertTrue(popover.waitToExist(timeout: 8), "Commented text should reopen its popover after relaunching.")
        XCTAssertTrue(commentField.waitToExist(timeout: 5))
        XCTAssertEqual(commentField.value as? String, "Explain it again", "The edited comment should be saved.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Escape should close the popover without changes.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("pending-comment-count")).contains("1 comment"), "Escape keeps the comment.")
        clickBothAndChoose("Side chat", context: "after relaunching")
        XCTAssertTrue(bubble.waitToExist(timeout: 8))
        XCTAssertTrue(element("side-chat-assistant-message-3").waitToExist(timeout: 5), "The side chat history should survive relaunching.")
        attachScreenshot(named: "Side chat reopened from the pill after relaunching")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))

        // Discard deletes the comment; the side chat stays, purple again.
        clickBothAndChoose("Comment", context: "before discarding")
        XCTAssertTrue(discardComment.waitToExist(timeout: 8))
        discardComment.click()
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Discarding the comment should close the popover.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 0 }, timeout: 10),
                      "Discard should delete the comment.")
        XCTAssertFalse(element("pending-comment-count").exists, "No pending comment should remain.")
        XCTAssertTrue(waitUntil({ self.purplePixelCount(in: reply.screenshot()) > purpleBefore + 5 }, timeout: 5),
                      "Discarding the comment should leave the side chat's purple text.")
        XCTAssertLessThan(orangePixelCount(in: reply.screenshot()), orangeBefore + 5)
        attachElementScreenshot(reply, named: "Discarded comment leaves the side chat purple")
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "With only its side chat left, clicking the text opens the bubble directly.")
        XCTAssertEqual(element("side-chat-user-message-2").label, "And then?", "The side chat should still reopen with its history.")
        XCTAssertEqual((try savedSideChats().first?["messages"] as? [[String: Any]])?.count, 4)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))

        // Text with only a comment opens its popover on click; saving it emptied deletes it.
        let questionID = try XCTUnwrap(ordinaryMessages(try XCTUnwrap(history["messages"] as? [[String: Any]]))
            .first { ($0["role"] as? String) == "user" }?["id"] as? String)
        var question: XCUIElement { element("user-message-\(questionID)").textViews.firstMatch }
        XCTAssertTrue(question.waitToExist(timeout: 5) || scrollTranscriptUntilExists(question))
        XCTAssertTrue(waitForStableFrame(question))
        question.click()
        question.typeKey("a", modifierFlags: .command)
        addCommentFromSelection("Clarify the question")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 1 }, timeout: 10))
        clickHighlightedText(question)
        XCTAssertTrue(popover.waitToExist(timeout: 8), "Clicking text with only a comment should open its popover.")
        XCTAssertFalse(bubble.exists, "Text with only a comment opens no side chat bubble.")
        XCTAssertEqual(commentField.value as? String, "Clarify the question")
        commentField.click()
        commentField.typeKey("a", modifierFlags: .command)
        commentField.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(saveComment.isEnabled, "An emptied comment can be saved to delete it.")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "Saving an empty comment should close the popover.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 0 }, timeout: 10),
                      "Saving an empty comment should delete it.")
        XCTAssertFalse(element("pending-comment-count").exists, "No pending comment should remain.")
    }
    // case-contract: test_side_chat_keeps_answering_after_bubble_closes | A side chat keeps answering in the background after its bubble closes. Through CLI/XPC, a first side chat message whose answer the provider holds completes once released and is saved with its exchange; closing the side chat with side-chat-close while a held follow-up is still answering does not stop it, and another message meanwhile is rejected as still answering rather than starting a second turn: once released the follow-up's answer is returned, saved after the earlier exchange and listed by conversation side-chats, and a further follow-up continues the same forked session, leaving the task's own session alone. In the app, the selected text turns purple as soon as the first question is sent; closing the bubble with Escape before the answer arrives and clicking the text reopens it with the question and Thinking, which the answer replaces once it arrives; after closing it while a held follow-up answers, going back to the board and reopening the task, clicking the text shows the answer that arrived meanwhile, and a further follow-up continues the same saved side chat.
    func test_side_chat_keeps_answering_after_bubble_closes() throws {
        _ = try installClaudeFixture(named: "claude-fixture-side-chat-hold")
        let executable = try XCTUnwrap(claudeFixtureExecutable)
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        launchApp(defaultParent: fixture.parent.path)
        let title = "Background side chat"
        let opened = try openSideChatOnReply(title: title)
        let history = try XCTUnwrap(try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])
        let replyID = try XCTUnwrap(ordinaryMessages(try XCTUnwrap(history["messages"] as? [[String: Any]]))
            .last { ($0["role"] as? String) == "assistant" }?["id"] as? String)
        // Looked up on each use: reopening the task renders the reply again.
        var reply: XCUIElement { element("assistant-message-\(replyID)").descendants(matching: .staticText).firstMatch }
        var bubble: XCUIElement { element("side-chat-bubble") }
        let purpleBefore = purplePixelCount(in: reply.screenshot())
        let ready = URL(fileURLWithPath: executable + ".side-chat-hold-ready")
        let release = URL(fileURLWithPath: executable + ".side-chat-hold-release")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: release)
        // A failure below must not leave the fixture holding its answer.
        defer { try? Data().write(to: release) }
        func savedMessageCount() -> Int {
            let chats = (try? self.runCLI(["conversation", "side-chats", opened.taskID]))?["result"] as? [[String: Any]]
            return (chats?.first?["messages"] as? [[String: Any]])?.count ?? 0
        }

        let question = "Please hold-side-chat until released."
        let input = element("side-chat-input")
        XCTAssertTrue(input.waitToExist(timeout: 5))
        input.click()
        input.typeText(question + "\r")
        XCTAssertTrue(element("side-chat-user-message-0").waitToExist(timeout: 10), "The bubble should show the question it sent.")
        XCTAssertEqual(element("side-chat-user-message-0").label, question)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 30),
                      "The fixture should hold the side chat's answer.")
        XCTAssertTrue(element("side-chat-responding").waitToExist(timeout: 5), "The bubble should show Thinking while the side chat answers.")
        attachElementScreenshot(bubble, named: "Side chat thinking before its answer arrives")

        // Closing the bubble before the answer arrives keeps the side chat answering, and its text
        // turns purple as soon as the question is sent.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Escape should close the side chat bubble while it answers.")
        XCTAssertTrue(waitUntil({ self.purplePixelCount(in: reply.screenshot()) > purpleBefore + 5 }, timeout: 5),
                      "The selected text should turn purple once the first question is sent.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path), "The answer should still be held.")
        attachElementScreenshot(reply, named: "Side-chatted text purple while its answer is held")
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking the text should reopen the answering side chat.")
        XCTAssertEqual(element("side-chat-user-message-0").label, question, "The reopened bubble should show the question.")
        XCTAssertTrue(element("side-chat-responding").waitToExist(timeout: 5), "The reopened bubble should still show Thinking.")
        XCTAssertFalse(element("side-chat-assistant-message-1").exists, "The held answer has not arrived yet.")
        attachScreenshot(named: "Reopened side chat still thinking in the background")

        // Released while the reopened bubble shows it, the answer replaces Thinking there.
        try Data().write(to: release)
        let answer = element("side-chat-assistant-message-1")
        XCTAssertTrue(waitUntil({ answer.exists && answer.label.contains("Side chat about") }, timeout: 30),
                      "The reopened bubble should show the answer once it arrives.")
        XCTAssertTrue(element("side-chat-responding").waitForNonExistence(timeout: 5), "The side chat is no longer answering.")
        XCTAssertTrue(waitUntil({ savedMessageCount() == 2 }, timeout: 10), "The answered exchange should be saved.")
        attachElementScreenshot(bubble, named: "Reopened side chat shows the answer replacing Thinking")

        // A held follow-up answers while the task is not even open, and is saved with its exchange.
        try? FileManager.default.removeItem(at: ready)
        let followUp = "Please hold-side-chat on the follow-up."
        input.click()
        input.typeText(followUp + "\r")
        XCTAssertTrue(element("side-chat-user-message-2").waitToExist(timeout: 10), "The bubble should show the follow-up it sent.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 30),
                      "The fixture should hold the follow-up's answer.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        try Data().write(to: release)
        XCTAssertTrue(waitUntil({ savedMessageCount() == 4 }, timeout: 30),
                      "The side chat should save the follow-up's exchange once it answers in the background.")
        openTask(named: title)
        XCTAssertTrue(reply.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertTrue(waitForStableFrame(reply))
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking the text should reopen the side chat.")
        let followUpAnswer = element("side-chat-assistant-message-3")
        XCTAssertTrue(waitUntil({ followUpAnswer.exists && followUpAnswer.label.contains("Side chat follow-up 2 on") }, timeout: 10),
                      "The reopened bubble should show the answer that arrived in the background.")
        XCTAssertFalse(element("side-chat-responding").exists, "The side chat is no longer answering.")
        attachScreenshot(named: "Reopened side chat shows the answer that arrived in the background")
        _ = sendSideChatMessage("And after that?", answerIndex: 5, containing: "Side chat follow-up 3 on")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
        XCTAssertEqual(savedMessageCount(), 6, "The follow-up continues the same saved side chat.")
    }
    // case-contract: test_claude_auto_branch_uses_generated_title_and_fallback | An Untitled Claude task with a pending auto repository branch uses its selected provider to generate the title before worktree creation; the branch and title persist across fresh CLI/XPC reads and the visible task. If Claude title generation returns no title, the prompt becomes the title and branch fallback, and the conversation still starts in that worktree. A fresh `task title` request reproduces the generated title and provider (null when generation yields nothing), and `task reconcile` returns the settled task unchanged.
    func test_claude_auto_branch_uses_generated_title_and_fallback() throws {
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        for (index, variant) in ["title-success", "title-failure"].enumerated() {
            let executable = dataDirectory.appendingPathComponent("claude-fixture-\(variant)")
            try copyFixtureFile(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            claudeFixtureExecutable = executable.path
            if index == 0 { launchApp(defaultParent: fixture.parent.path) } else { relaunchApp() }
            let created = try XCTUnwrap(try runCLI([
                "task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--provider", "claude"
            ])["result"] as? [String: Any])
            let taskID = try XCTUnwrap(created["id"] as? String)
            XCTAssertEqual((created["repositoryWorktrees"] as? [[String: Any]])?.first?["branch"] as? String, "auto")
            openTask(named: "Untitled task")
            let prompt = variant == "title-success" ? "Explain the selected Claude task." : "Explain Claude fallback title"
            let expectedTitle = variant == "title-success" ? "Generated Claude title" : prompt
            let expectedBranch = variant == "title-success" ? "generated-claude-title" : "explain-claude-fallback-title"
            let composer = element("message-composer")
            XCTAssertTrue(composer.waitToExist(timeout: 10))
            composer.click()
            composer.typeText(prompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                guard let record = try? self.taskRecord(id: taskID),
                      let worktree = (record["repositoryWorktrees"] as? [[String: Any]])?.first else { return false }
                return record["title"] as? String == expectedTitle
                    && worktree["branch"] as? String == expectedBranch
                    && worktree["isPending"] as? Bool == false
            }, timeout: 20), "Claude's generated or fallback title should determine the auto branch before the turn.")
            let record = try XCTUnwrap(taskRecord(id: taskID))
            let worktree = try XCTUnwrap((record["repositoryWorktrees"] as? [[String: Any]])?.first)
            let worktreePath = try XCTUnwrap(worktree["worktreePath"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))
            try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(expectedBranch)")
            XCTAssertEqual(record["savedPrompt"] as? String, prompt)
            XCTAssertEqual(record["conversationProvider"] as? String, "claude")
            XCTAssertTrue(transcriptMessage(prompt).waitToExist(timeout: 10))
            let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
            XCTAssertTrue(messages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == prompt })
            let generated = try runCLI(["task", "title", taskID, "--prompt", prompt])["result"]
            if variant == "title-success" {
                let generatedTitle = try XCTUnwrap(generated as? [String: Any])
                XCTAssertEqual(generatedTitle["title"] as? String, expectedTitle)
                XCTAssertEqual(generatedTitle["provider"] as? String, "claude")
            } else {
                XCTAssertTrue(generated == nil || generated is NSNull, "A provider that returns no title leaves the caller to fall back.")
            }
            XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) != "In Progress" }, timeout: 15), "The Claude turn should settle before reconciling.")
            let settled = try XCTUnwrap(taskRecord(id: taskID))
            let reconciled = try XCTUnwrap(try runCLI(["task", "reconcile", taskID])["result"] as? [String: Any])
            XCTAssertEqual(reconciled["id"] as? String, taskID)
            XCTAssertEqual(reconciled["status"] as? String, settled["status"] as? String)
            XCTAssertEqual(reconciled["title"] as? String, expectedTitle)
            element("back-to-board-button").click()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", expectedTitle)).firstMatch.waitToExist(timeout: 10),
                          "The saved Claude title should appear on the board.")
        }
    }
    // case-contract: test_conversation_runs_concurrent_claude_sends_in_parallel | Claude turns for different conversations run at the same time instead of queueing on a shared turn slot. While one task's turn is held active, a second task's send starts in its own Claude process, runs its own tool, and completes with its own user and assistant messages before the held turn is released. Each turn's process uses its own task working directory, each conversation keeps only its own activity rows and measured durations, diagnostics record no queued-slot event and no prompt text, and the second conversation's answer is available while the first turn is still running. The held conversation first completes a turn with a tool call. Before the held turn reports anything, its mid-turn history has only its question after that turn, with no assistant message or activity of its own, and it shows only a Thinking row with a spinner in place of an empty Working for, despite the earlier turn's tool call; once the turn settles, opening its Worked for shows no Thinking row.
    func test_conversation_runs_concurrent_claude_sends_in_parallel() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-parallel-sends")
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        try copyFixtureFile(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        claudeFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)

        let first = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Held Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let firstID = try XCTUnwrap(first["id"] as? String)
        let second = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Parallel Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let secondID = try XCTUnwrap(second["id"] as? String)
        let ready = URL(fileURLWithPath: executable.path + ".concurrent-turn-ready")
        let release = URL(fileURLWithPath: executable.path + ".concurrent-turn-release")
        defer {
            if FileManager.default.fileExists(atPath: ready.path) {
                try? "Release the first Claude turn.\n".write(to: release, atomically: true, encoding: .utf8)
            }
        }

        let firstPrompt = "Please hold-claude-turn-for-concurrency."
        let secondPrompt = "Inspect the workspace while the other conversation is busy."
        openTask(named: "Held Claude conversation")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        // An earlier turn with a tool call stays inline above the held turn; it is not this turn's activity.
        let earlierPrompt = "Summarize the release notes."
        composer.click()
        composer.typeText(earlierPrompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.fixtureTurnCount(executable, containing: earlierPrompt) > 0 && self.noTurnIsRunning() }, timeout: 30),
                      "The earlier tool-using turn should finish before the held turn starts.")
        let earlierActivityIDs = Set(((try runCLI(["conversation", "history", firstID])["result"] as? [String: Any])?["activities"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String })
        XCTAssertTrue(earlierActivityIDs.contains("toolu_chat_read"), "The earlier turn should record its tool call.")
        composer.click()
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The first Claude turn should be active before the second conversation starts.")
        // Nothing has been reported yet, so Thinking stands in for an empty Working for.
        let thinking = element("codex-activity-thinking")
        XCTAssertTrue(thinking.waitToExist(timeout: 10), "A held turn with no progress yet should show Thinking.")
        XCTAssertEqual(thinking.label, "Thinking…")
        XCTAssertFalse(element("codex-activity-disclosure").exists, "An empty Working for should not render beside Thinking.")
        let heldHistory = try XCTUnwrap(try runCLI(["conversation", "history", firstID])["result"] as? [String: Any])
        let heldMessages = heldHistory["messages"] as? [[String: Any]] ?? []
        let heldQuestionIndex = try XCTUnwrap(heldMessages.lastIndex { ($0["role"] as? String) == "user" && ($0["text"] as? String) == firstPrompt })
        XCTAssertTrue(heldMessages[(heldQuestionIndex + 1)...].allSatisfy { ($0["role"] as? String) != "assistant" },
                      "The held turn should have no assistant message yet.")
        XCTAssertTrue(Set((heldHistory["activities"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }).isSubset(of: earlierActivityIDs),
                      "The held turn should have no activity of its own yet.")
        attachAppWindowScreenshot(named: "Thinking before the turn reports progress")

        // Both turns run inside this one Playhouse process: the second
        // conversation must be usable and answer while the first is held.
        element("back-to-board-button").click()
        openTask(named: "Parallel Claude conversation")
        let parallelComposer = element("message-composer")
        XCTAssertTrue(parallelComposer.waitToExist(timeout: 10))
        parallelComposer.click()
        parallelComposer.typeText(secondPrompt)
        let parallelSend = element("send-message-button")
        XCTAssertTrue(parallelSend.isEnabled, "A Claude turn in another conversation must not block this conversation's composer.")
        parallelSend.click()
        XCTAssertTrue(app.staticTexts["Inspection done: the workspace is ready."].waitToExist(timeout: 30),
                      "The parallel conversation should show its own answer while the other turn is held.")
        XCTAssertEqual(try taskRecord(id: firstID)?["status"] as? String, "In Progress",
                       "The held turn must still be running when the parallel conversation finishes.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: secondID)?["status"] as? String) == "Waiting Response" }, timeout: 15))
        let diagnosticText = String(data: try JSONSerialization.data(withJSONObject: try diagnosticEvents()), encoding: .utf8) ?? ""
        XCTAssertFalse(diagnosticText.contains("claude.turn.queued"), "Parallel Claude turns must not wait on a shared turn slot.")
        XCTAssertFalse(diagnosticText.contains(firstPrompt))
        XCTAssertFalse(diagnosticText.contains(secondPrompt))

        try "Release the first Claude turn.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: firstID)?["status"] as? String) == "Waiting Response" }, timeout: 20))
        element("back-to-board-button").click()
        openTask(named: "Held Claude conversation")
        XCTAssertTrue(app.staticTexts["OK."].waitToExist(timeout: 20),
                      "The held conversation should show its own answer once released.")
        // Opening the settled, still empty Worked for must not bring Thinking back.
        let disclosure = element("codex-activity-disclosure")
        XCTAssertTrue(waitUntil({ disclosure.exists && disclosure.label.hasPrefix("Worked for") }, timeout: 10),
                      "The settled turn should fold into Worked for.")
        disclosure.click()
        XCTAssertTrue(waitUntil({ disclosure.value as? String == "Expanded, down chevron" }, timeout: 5))
        XCTAssertFalse(thinking.exists, "Thinking should disappear once the turn settles.")

        let firstHistory = try XCTUnwrap(try runCLI(["conversation", "history", firstID])["result"] as? [String: Any])
        let firstMessages = firstHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(firstMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == firstPrompt })
        XCTAssertTrue(firstMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "OK." })
        let secondHistory = try XCTUnwrap(try runCLI(["conversation", "history", secondID])["result"] as? [String: Any])
        let secondMessages = secondHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(secondMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == secondPrompt })
        XCTAssertTrue(secondMessages.contains {
            ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "Inspection done: the workspace is ready."
        })

        // Activity rows and their measured durations belong to the conversation
        // that ran them, not to whichever Claude turn finished last.
        let parallelRows = (secondHistory["activities"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) == "toolu_read" }
        XCTAssertEqual(parallelRows.count, 1, "The parallel conversation should keep its own activity row.")
        XCTAssertEqual(parallelRows.first?["status"] as? String, "completed")
        XCTAssertGreaterThan(parallelRows.first?["durationMs"] as? Int ?? 0, 0,
                             "The parallel conversation's activity should persist its measured duration.")
        XCTAssertTrue((firstHistory["activities"] as? [[String: Any]] ?? []).allSatisfy { ($0["id"] as? String) != "toolu_read" },
                      "The held conversation must not inherit the parallel conversation's activity.")

        // Each turn ran its CLI process inside its own task worktree.
        let fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        ) as? [String: Any])
        let turns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        func workingDirectory(forPrompt prompt: String) -> String? {
            turns.first { ($0["userText"] as? String) == prompt }.flatMap { $0["cwd"] as? String }
        }
        let firstWorktree = try XCTUnwrap((try taskRecord(id: firstID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        let secondWorktree = try XCTUnwrap((try taskRecord(id: secondID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        XCTAssertEqual(workingDirectory(forPrompt: firstPrompt).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: firstWorktree).resolvingSymlinksInPath().path)
        XCTAssertEqual(workingDirectory(forPrompt: secondPrompt).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: secondWorktree).resolvingSymlinksInPath().path)
    }
    // case-contract: test_conversation_isolates_failing_claude_turn_from_parallel_send | A failing Claude turn does not disturb a conversation running in parallel. While one task's turn is held and then fails, a second task's send from a separate process completes on its own session and reaches Waiting Response; the failing task keeps its user message in its conversation, where the open and reopened task show it, with an empty composer and no unsent draft, records no final answer, and its provider process exit is the only failure in diagnostics. The UI shows the parallel answer after reopening its task with fresh history. While the failing task's conversation is open and its turn held, the parallel turn starts, finishes and advances only its own revision: CLI/XPC runtime still reports the held session active and interruptible and the parallel session inactive, and the open conversation still offers an enabled Stop and never shows the parallel answer.
    func test_conversation_isolates_failing_claude_turn_from_parallel_send() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-parallel-failure")
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        try copyFixtureFile(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        claudeFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)

        let first = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Failing Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let firstID = try XCTUnwrap(first["id"] as? String)
        let second = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Unaffected Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let secondID = try XCTUnwrap(second["id"] as? String)
        let ready = URL(fileURLWithPath: executable.path + ".concurrent-turn-ready")
        let release = URL(fileURLWithPath: executable.path + ".concurrent-turn-release")
        defer {
            if FileManager.default.fileExists(atPath: ready.path) {
                try? "Fail the first Claude turn.\n".write(to: release, atomically: true, encoding: .utf8)
            }
        }

        let firstPrompt = "Please fail-after-hold-claude-turn-for-concurrency."
        let secondPrompt = "Second Claude turn after failure."
        openTask(named: "Failing Claude conversation")
        let firstComposer = element("message-composer")
        XCTAssertTrue(firstComposer.waitToExist(timeout: 10))
        firstComposer.click()
        firstComposer.typeText(firstPrompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15))
        let secondProcess = try startCLIProcess(
            ["conversation", "send", secondID, "--message", secondPrompt],
            extraEnvironment: ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": executable.path]
        )
        let secondResult = try finishCLIProcess(secondProcess)
        XCTAssertEqual(secondResult["ok"] as? Bool, true)
        XCTAssertEqual(try taskRecord(id: firstID)?["status"] as? String, "In Progress",
                       "The failing turn must still be held while the parallel conversation completes.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: secondID)?["status"] as? String) == "Waiting Response" }, timeout: 10))
        // The parallel turn started, finished and advanced its own revision while this
        // conversation stayed open. The open conversation follows only its own runtime state:
        // its held turn still shows as running and can be stopped, and the other answer stays out.
        let heldSessionID = try XCTUnwrap(try taskRecord(id: firstID)?["claudeSessionID"] as? String)
        let parallelSessionID = try XCTUnwrap(try taskRecord(id: secondID)?["claudeSessionID"] as? String)
        XCTAssertNotEqual(heldSessionID, parallelSessionID)
        let parallelRuntime = try XCTUnwrap(try runCLI(["conversation", "runtime"])["result"] as? [String: Any])
        XCTAssertTrue((parallelRuntime["activeThreadIDs"] as? [String] ?? []).contains(heldSessionID), "The held turn stays active.")
        XCTAssertTrue((parallelRuntime["interruptibleThreadIDs"] as? [String] ?? []).contains(heldSessionID), "The held turn stays interruptible.")
        XCTAssertFalse((parallelRuntime["activeThreadIDs"] as? [String] ?? []).contains(parallelSessionID), "The parallel turn has ended.")
        XCTAssertNotNil((parallelRuntime["conversationRevisions"] as? [String: Any])?[secondID], "The parallel turn advanced its own revision.")
        let heldStop = element("pause-response-button")
        XCTAssertTrue(heldStop.waitToExist(timeout: 5), "The open conversation's held turn still offers Stop after another task's turn.")
        XCTAssertTrue(heldStop.isEnabled, "Stop stays enabled while the open conversation's own turn is held.")
        XCTAssertFalse(transcriptMessage("OK.").exists, "The parallel conversation's answer must not appear in the open one.")
        attachScreenshot(named: "Open conversation keeps its held turn after a parallel task answers")

        try "Fail the first Claude turn.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "claude.process.exited" && $0["exitStatus"] as? String == "1"
            }) == true
        }, timeout: 15), "The failing Claude process exit should be recorded.")
        let firstSessionID = try XCTUnwrap(try taskRecord(id: firstID)?["claudeSessionID"] as? String)
        let failureThreadIDs = Set(try diagnosticEvents().filter {
            $0["event"] as? String == "claude.process.exited" && $0["exitStatus"] as? String == "1"
        }.compactMap { $0["activeThreadID"] as? String })
        XCTAssertEqual(failureThreadIDs, [firstSessionID], "Only the failing conversation's Claude process should exit with a failure.")
        // The failed send keeps its prompt in the conversation, so it isn't also returned to the composer.
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "The failing turn should be reported in its conversation.")
        XCTAssertTrue(transcriptMessage(firstPrompt).exists, "The failing turn's prompt stays in its conversation.")
        XCTAssertEqual(firstComposer.value as? String, "", "The failing turn's prompt must not return to the composer.")
        XCTAssertEqual(try taskRecord(id: firstID)?["hasUnsentDraft"] as? Bool, false, "The failing turn's prompt must not be saved as an unsent draft.")
        attachScreenshot(named: "Failed Claude turn keeps its prompt in the conversation with an empty composer")

        let firstHistory = try XCTUnwrap(try runCLI(["conversation", "history", firstID])["result"] as? [String: Any])
        let firstMessages = firstHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(firstMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == firstPrompt })
        XCTAssertFalse(firstMessages.contains { $0["phase"] as? String == "final_answer" })
        let secondHistory = try XCTUnwrap(try runCLI(["conversation", "history", secondID])["result"] as? [String: Any])
        let secondMessages = secondHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(secondMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == secondPrompt })
        XCTAssertTrue(secondMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "OK." })

        returnToBoard()
        openTask(named: "Failing Claude conversation")
        XCTAssertTrue(transcriptMessage(firstPrompt).waitToExist(timeout: 15), "Reopening keeps the failing prompt in the conversation.")
        XCTAssertEqual(element("message-composer").value as? String, "", "Reopening must not restore the failing prompt to the composer.")
        returnToBoard()
        openTask(named: "Unaffected Claude conversation")
        XCTAssertTrue(app.staticTexts["OK."].waitToExist(timeout: 15), "The reopened UI should show the parallel answer from persisted history.")
    }
    // case-contract: test_claude_stop_leaves_parallel_conversation_running | Stopping one Claude turn pauses only that conversation while a second Claude conversation runs in parallel. The parallel conversation answers and keeps its own activity rows and measured durations while the first turn is still thinking; the stopped task moves to Waiting Response with no failure reason, records no answer, and leaves the parallel task's Waiting Response result untouched. A fresh CLI/XPC read confirms both results.
    func test_claude_stop_leaves_parallel_conversation_running() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-parallel-stop")
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        try copyFixtureFile(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        claudeFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)

        let stopped = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Stopped Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let stoppedID = try XCTUnwrap(stopped["id"] as? String)
        let running = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Running Claude conversation", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path, "--provider", "claude"
        ])["result"] as? [String: Any])
        let runningID = try XCTUnwrap(running["id"] as? String)
        let ready = URL(fileURLWithPath: executable.path + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable.path + ".interrupt-received")
        let release = URL(fileURLWithPath: executable.path + ".interrupt-release")
        defer {
            if FileManager.default.fileExists(atPath: ready.path) {
                try? "acknowledge interrupt\n".write(to: release, atomically: true, encoding: .utf8)
            }
        }

        let parallelPrompt = "Inspect the workspace while the other conversation is busy."
        openTask(named: "Stopped Claude conversation")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15),
                      "Claude should be actively thinking in the first conversation before the second one starts.")

        // The second conversation runs its own Claude turn in this same process.
        element("back-to-board-button").click()
        openTask(named: "Running Claude conversation")
        let parallelComposer = element("message-composer")
        XCTAssertTrue(parallelComposer.waitToExist(timeout: 10))
        parallelComposer.click()
        parallelComposer.typeText(parallelPrompt)
        element("send-message-button").click()
        XCTAssertTrue(app.staticTexts["Inspection done: the workspace is ready."].waitToExist(timeout: 30),
                      "The parallel conversation should answer while the other turn is still thinking.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: runningID)?["status"] as? String) == "Waiting Response" }, timeout: 15))
        XCTAssertEqual(try taskRecord(id: stoppedID)?["status"] as? String, "In Progress")

        element("back-to-board-button").click()
        openTask(named: "Stopped Claude conversation")
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.isEnabled }, timeout: 10), "Stop should be enabled while this conversation's turn is active.")
        stop.click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: stoppedID)?["status"] as? String) == "Waiting Response" }, timeout: 10))
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10),
                      "Claude should receive its native interrupt for the stopped conversation.")
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 20),
                      "The stopped turn should reset its own composer to the resumable state.")

        // Only the stopped conversation carries the paused result.
        XCTAssertEqual(try taskRecord(id: stoppedID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: stoppedID)?["statusMessage"] as? String,
                     "A user-requested stop should not leave a failure reason.")
        XCTAssertEqual(try taskRecord(id: runningID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: runningID)?["statusMessage"] as? String,
                     "Stopping one conversation must not mark the parallel conversation as failed.")

        let stoppedHistory = try XCTUnwrap(try runCLI(["conversation", "history", stoppedID])["result"] as? [String: Any])
        let stoppedMessages = stoppedHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(stoppedMessages.contains { $0["phase"] as? String == "final_answer" },
                       "The stopped conversation must not record an answer.")
        let runningHistory = try XCTUnwrap(try runCLI(["conversation", "history", runningID])["result"] as? [String: Any])
        let runningMessages = runningHistory["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(runningMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == parallelPrompt })
        XCTAssertTrue(runningMessages.contains {
            ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "Inspection done: the workspace is ready."
        })
        let runningRows = (runningHistory["activities"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) == "toolu_read" }
        XCTAssertEqual(runningRows.count, 1, "The parallel conversation should keep its own activity row.")
        XCTAssertGreaterThan(runningRows.first?["durationMs"] as? Int ?? 0, 0)
        XCTAssertTrue((stoppedHistory["activities"] as? [[String: Any]] ?? []).allSatisfy { ($0["id"] as? String) != "toolu_read" },
                      "The stopped conversation must not inherit the parallel conversation's activity.")
    }
    // case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, the task remains In Progress while a send is active, and successful turns without outcome calls finish in Waiting Response.
    func test_conversation_serializes_concurrent_sends() throws {
        let sharedFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-concurrent-serial-success-wait")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sharedFixture.path))
        for suffix in ["resolve-ready", "resolve-continue", "serial-second-turn-started", "history"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sharedFixture.path + ".\(suffix)"))
        }
        codexFixtureExecutable = sharedFixture.path
        launchApp(defaultParent: fixture.parent.path)

        let created = try runCLI(["task", "create", "--title", "Concurrent conversation sends", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        let task = try XCTUnwrap(created["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertEqual(task["status"] as? String, "Backlog")
        let firstPrompt = "First serialized message."
        let secondPrompt = "Second serialized message."
        let secondCommand = ["conversation", "send", taskID, "--message", secondPrompt]
        let firstReady = URL(fileURLWithPath: sharedFixture.path + ".resolve-ready")
        let firstRelease = URL(fileURLWithPath: sharedFixture.path + ".resolve-continue")
        let secondStarted = URL(fileURLWithPath: sharedFixture.path + ".serial-second-turn-started")
        var secondTurn: RunningCLIProcess?
        defer {
            if FileManager.default.fileExists(atPath: firstReady.path) {
                try? "Release the first serialized turn.\n".write(to: firstRelease, atomically: true, encoding: .utf8)
            }
            if let secondTurn, secondTurn.process.isRunning { secondTurn.process.terminate(); secondTurn.process.waitUntilExit() }
        }

        openTask(named: "Concurrent conversation sends")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        let firstTurnPaused = waitUntil({ FileManager.default.fileExists(atPath: firstReady.path) }, timeout: 15)
        let fixtureHistoryURL = URL(fileURLWithPath: sharedFixture.path + ".history")
        let fixtureHistory = (try? String(contentsOf: fixtureHistoryURL, encoding: .utf8)) ?? "<no history>"
        let fixtureSidecars = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path))?
            .filter { $0.hasPrefix(URL(fileURLWithPath: sharedFixture.path).lastPathComponent) }
            .sorted() ?? []
        XCTAssertTrue(
            firstTurnPaused,
            "The first UI send should pause in the local app-server fixture before the CLI send begins. Fixture sidecars=\(fixtureSidecars); history=\(fixtureHistory)"
        )
        let activeStatus = try XCTUnwrap(taskRecord(id: taskID)?["status"] as? String)
        XCTAssertEqual(activeStatus, "In Progress", "The active UI send should keep the task In Progress.")
        secondTurn = try startCLIProcess(
            secondCommand,
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": sharedFixture.path]
        )
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(secondTurn?.process.isRunning == true, "The second send should wait for the conversation-turn reservation held by the first send.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStarted.path), "The shared app-server fixture must not receive the second turn until the first send releases its reservation.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "A queued same-task send must not mark the task Blocked.")

        try "Release the first serialized turn.\n".write(to: firstRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("send-message-button").waitToExist(timeout: 15), "The UI send should finish after the fixture is released.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: secondStarted.path) }, timeout: 15), "The CLI send should start after the UI turn releases its reservation.")
        let secondResponse = try finishCLIProcess(try XCTUnwrap(secondTurn))
        XCTAssertTrue(secondResponse["ok"] as? Bool == true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStarted.path), "The second app-server turn should begin after the first releases its reservation.")
        let savedHistory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sharedFixture.path + ".history"))) as? [String: Any]
        )
        // Playhouse's private outcome reminders are separate turns, not user messages.
        let persistedPrompts = try XCTUnwrap(savedHistory["messages"] as? [[String: Any]]).compactMap { $0["userMessage"] as? String }
            .filter { !$0.hasPrefix("Playhouse internal outcome nudge:") }
        XCTAssertEqual(persistedPrompts, [firstPrompt, secondPrompt], "Both messages should persist in the same local Codex thread history.")
        let threadID = try XCTUnwrap(savedHistory["threadID"] as? String)
        let protocolEvents = try XCTUnwrap(savedHistory["events"] as? [[String: Any]])
        let threadEvents = protocolEvents.filter { ($0["method"] as? String)?.hasPrefix("thread/") == true }
        XCTAssertEqual(threadEvents.compactMap { $0["method"] as? String }.filter { $0 == "thread/start" }.count, 1)
        XCTAssertGreaterThanOrEqual(threadEvents.compactMap { $0["method"] as? String }.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertTrue(protocolEvents.allSatisfy { $0["threadID"] as? String == threadID })
        let persistedTurns = try XCTUnwrap(savedHistory["messages"] as? [[String: Any]])
        XCTAssertTrue(persistedTurns.allSatisfy { $0["threadID"] as? String == threadID })
        let turnIDs = persistedTurns
            .filter { ($0["userMessage"] as? String)?.hasPrefix("Playhouse internal outcome nudge:") != true }
            .compactMap { $0["turnID"] as? String }
        XCTAssertEqual(turnIDs.count, 2)
        XCTAssertEqual(Set(turnIDs).count, 2, "Each concurrent send should use a distinct Codex turn ID.")
        XCTAssertEqual(
            protocolEvents.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["turnID"] as? String },
            persistedTurns.compactMap { $0["turnID"] as? String }
        )
        let completed = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(completed["codexThreadID"] as? String, threadID)
        XCTAssertEqual(completed["status"] as? String, "Waiting Response")

        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible("Concurrent conversation sends", inColumn: "Waiting Response")
        openTask(named: "Concurrent conversation sends")
        let conversation = element("conversation-scroll-view")
        let firstPersistedMessage = conversation.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", firstPrompt)).firstMatch
        let secondPersistedMessage = conversation.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", secondPrompt)).firstMatch
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        XCTAssertTrue(firstPersistedMessage.waitToExist(timeout: 10), "Reopening the task should retain the first completed send in conversation history.")
        XCTAssertTrue(secondPersistedMessage.waitToExist(timeout: 10), "Reopening the task should load the completed second send from the real app-server thread.")
    }
}

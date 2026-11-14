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
    // case-contract: test_conversation_persists_unsent_comments | Unsent conversation comments are saved with the task draft. Through CLI/XPC, a saved comment list reports its count on a fresh read, malformed input is rejected with invalid_argument and leaves the saved comments unchanged, a later draft save keeps them, appending a list adds only comments not already saved (how a send that ends without delivering its comments returns them without overwriting newer ones), and an empty list clears them. Saving comments after a sent prompt leaves hasUnsentDraft false, so the sent prompt never returns to the composer as a draft. In the app, comments added to a conversation are saved as they are added and survive switching to another task and back and quitting and relaunching: the composer shows the pending comment count and the highlights are restored. Sending them delivers their source ranges, clears the saved comments, and reopening the task shows no pending comment and no duplicate. Once sent, a comment can no longer be edited (task comments edit reports not_found), and clicking its text reopens it read-only in the side chat bubble, whose Comment button can still add a new comment there.
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
        // The reply sits below the top of the transcript, so the Side chat hint above it stays clickable.
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
        let bubble = try waitForSideChatBubble(at: sourceView)
        let field = element("side-chat-input")
        XCTAssertTrue(field.waitToExist(timeout: 5))
        field.typeText("Keep this unsent comment")
        element("add-comment-button").click()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5))
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
        // The sent comment stays orange; clicking it reopens it read-only, beside a Comment button.
        XCTAssertTrue(sourceView.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertTrue(waitForStableFrame(sourceView))
        clickHighlightedText(sourceView)
        let sentBubble = element("side-chat-bubble")
        XCTAssertTrue(sentBubble.waitToExist(timeout: 8), "Clicking a sent comment's text should reopen its bubble.")
        let sentComment = element("side-chat-comment-text")
        XCTAssertTrue(sentComment.waitToExist(timeout: 5), "A sent comment should show in the reopened bubble.")
        XCTAssertTrue(accessibleLabelOrValue(of: sentComment).contains("Keep this unsent comment"))
        XCTAssertFalse(element("side-chat-comment-field").exists, "A sent comment can't be edited.")
        XCTAssertFalse(element("side-chat-comment-save").exists)
        XCTAssertTrue(element("add-comment-button").exists, "Another comment can still be added on a sent comment's text.")
        attachElementScreenshot(sentBubble, named: "Sent comment reopened read-only")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sentBubble.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("pending-comment-count").exists, "Reopening a sent comment adds no pending comment.")

        element("back-to-board-button").click()
        openTask(named: "Unsent comments")
        XCTAssertTrue(sourceView.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertFalse(element("pending-comment-count").waitToExist(timeout: 3),
                       "Reopening after the send should show no stale pending comment.")
        XCTAssertEqual(try taskRecord(id: taskID)?["pendingCommentCount"] as? Int, 0)
        attachScreenshot(named: "Sent comment reopened without a pending duplicate")
    }
    // case-contract: test_side_chat_and_comment_reopen_from_highlighted_text | Clicking commented or side-chatted conversation text, without selecting any, reopens its bubble with that selection's comment and side chat. A side chat opened on a selection is saved on the task with its source range, selected text, provider conversation, model and every answered exchange; closing its bubble keeps it, its text renders purple while no comment covers it and orange once a comment does, and reopening it shows its history and continues the same forked conversation, so its next answer is saved after the earlier ones. An unsent comment opens in an editable field: saving changed text keeps the comment with the new text, and clearing it and saving deletes it, leaving the side chat and its purple text. Through CLI/XPC, conversation side-chats lists the saved side chats, a side chat's source must name a message and a non-empty range, task comments edit changes an unsent comment's text, empty text deletes it, and an unknown comment is not_found. Edits and side chats survive a fresh read and relaunching the app.
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

        // The side chat's text is purple, and clicking it reopens the bubble with its history.
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking side-chatted text should reopen its bubble.")
        XCTAssertGreaterThan(purplePixelCount(in: reply.screenshot()), purpleBefore + 5, "A side chat without a comment should color its text purple.")
        XCTAssertLessThan(orangePixelCount(in: reply.screenshot()), orangeBefore + 5, "Side-chatted text without a comment is not orange.")
        XCTAssertEqual(element("side-chat-user-message-0").label, "What does this mean?", "The reopened bubble should show the saved question.")
        XCTAssertTrue(element("side-chat-assistant-message-1").label.contains("Side chat about"), "The reopened bubble should show the saved answer.")
        XCTAssertFalse(element("side-chat-comment-field").exists, "A side chat without a comment has no comment to edit.")
        XCTAssertTrue(element("add-comment-button").exists, "A side chat without a comment can still add one.")
        attachScreenshot(named: "Side chat reopened from its purple text")
        _ = sendSideChatMessage("And then?", answerIndex: 3, containing: "Side chat follow-up 2 on")

        // Adding a comment on the same text turns it orange.
        let input = element("side-chat-input")
        input.click()
        input.typeText("Explain the parser here")
        element("add-comment-button").click()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Add comment should close the bubble.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 1 }, timeout: 10))
        XCTAssertTrue(waitUntil({ self.orangePixelCount(in: reply.screenshot()) > orangeBefore + 5 }, timeout: 5),
                      "Text with both a comment and a side chat should be orange.")
        XCTAssertLessThan(purplePixelCount(in: reply.screenshot()), purpleBefore + 5, "The comment's orange should cover the side chat's purple.")
        attachElementScreenshot(reply, named: "Commented side chat text renders orange")

        // Clicking it reopens the comment, editable, beside the side chat's history.
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking commented text should reopen its bubble.")
        let commentField = element("side-chat-comment-field")
        XCTAssertTrue(commentField.waitToExist(timeout: 5), "The reopened bubble should show the comment in an editable field.")
        XCTAssertEqual(commentField.value as? String, "Explain the parser here")
        XCTAssertTrue(element("side-chat-assistant-message-3").label.contains("Side chat follow-up 2 on"), "The side chat history should show beside the comment.")
        XCTAssertFalse(element("add-comment-button").exists, "An existing comment is edited in its field, not added again.")
        XCTAssertFalse(element("side-chat-comment-save").isEnabled, "An unchanged comment has nothing to save.")
        attachScreenshot(named: "Comment and side chat reopened together")
        commentField.click()
        commentField.typeKey("a", modifierFlags: .command)
        commentField.typeText("Explain it again")
        attachElementScreenshot(bubble, named: "Comment edited in the reopened bubble")
        element("side-chat-comment-save").click()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Saving the comment should close the bubble.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("pending-comment-count")).contains("1 comment"), "Editing keeps the one comment.")

        // The edit and the side chat survive relaunching.
        Thread.sleep(forTimeInterval: 1)
        relaunchApp()
        openTask(named: title)
        XCTAssertTrue(reply.waitToExist(timeout: 10) || revealWholeTranscript())
        XCTAssertTrue(waitForStableFrame(reply))
        // The saved side chats load beside the transcript; the bubble opens with what is loaded.
        Thread.sleep(forTimeInterval: 1)
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Commented text should reopen its bubble after relaunching.")
        XCTAssertTrue(commentField.waitToExist(timeout: 5))
        XCTAssertEqual(commentField.value as? String, "Explain it again", "The edited comment should be saved.")
        XCTAssertTrue(element("side-chat-assistant-message-3").waitToExist(timeout: 5), "The side chat history should survive relaunching.")
        attachScreenshot(named: "Edited comment and side chat after relaunching")

        // Clearing the comment and saving deletes it; the side chat stays, purple again.
        commentField.click()
        commentField.typeKey("a", modifierFlags: .command)
        commentField.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("side-chat-comment-save").isEnabled, "An emptied comment can be saved to delete it.")
        element("side-chat-comment-save").click()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Saving an empty comment should close the bubble.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: opened.taskID)?["pendingCommentCount"] as? Int) == 0 }, timeout: 10),
                      "Saving an empty comment should delete it.")
        XCTAssertFalse(element("pending-comment-count").exists, "No pending comment should remain.")
        XCTAssertTrue(waitUntil({ self.purplePixelCount(in: reply.screenshot()) > purpleBefore + 5 }, timeout: 5),
                      "Deleting the comment should leave the side chat's purple text.")
        XCTAssertLessThan(orangePixelCount(in: reply.screenshot()), orangeBefore + 5)
        attachElementScreenshot(reply, named: "Deleted comment leaves the side chat purple")
        clickHighlightedText(reply)
        XCTAssertTrue(bubble.waitToExist(timeout: 8))
        XCTAssertFalse(element("side-chat-comment-field").exists, "The deleted comment should not reopen.")
        XCTAssertEqual(element("side-chat-user-message-2").label, "And then?", "The side chat should still reopen with its history.")
        XCTAssertEqual((try savedSideChats().first?["messages"] as? [[String: Any]])?.count, 4)
        app.typeKey(.escape, modifierFlags: [])
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
    // case-contract: test_conversation_runs_concurrent_claude_sends_in_parallel | Claude turns for different conversations run at the same time instead of queueing on a shared turn slot. While one task's turn is held active, a second task's send starts in its own Claude process, runs its own tool, and completes with its own user and assistant messages before the held turn is released. Each turn's process uses its own task working directory, each conversation keeps only its own activity rows and measured durations, diagnostics record no queued-slot event and no prompt text, and the second conversation's answer is available while the first turn is still running.
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
        composer.click()
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The first Claude turn should be active before the second conversation starts.")

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

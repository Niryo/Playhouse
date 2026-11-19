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
    // case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, logs task.create.succeeded for its ID, verifies empty history, and deletes it cleanly. New Task logs start and completion events with the same attempt ID and created task ID, then opens one empty conversation with the repository picker closed, the composer focused, and no create sheet. With no selected repositories, the empty conversation prominently says no repository is selected and, in place of the send-a-message prompt, shows a standalone round + button with its explanation, Add repositories to the task's context, as separate text centered below it; the + opens the header's Add repository picker and keeps the typed draft; typing starts immediately and, with a configured repository root, the UI enables standalone Send. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    func test_new_task_has_empty_conversation_history() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains { $0["event"] as? String == "ui.new_task.started" }) ?? false
        }, timeout: 2), "The New Task start event should reach the diagnostics file promptly after the click.")
        XCTAssertEqual(app.windows.count, 1, "New Task should open one conversation window.")
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: repositoryTitle()), "No repository selected")
        let repositorySearch = element("conversation-repository-search")
        XCTAssertFalse(repositorySearch.exists, "The new conversation should keep the repository picker closed by default.")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.typeText("Standalone draft")
        XCTAssertEqual(composer.value as? String, "Standalone draft", "The composer should receive typing immediately.")
        XCTAssertFalse(element("create-task-button").exists, "Direct task creation should not present a create sheet.")
        XCTAssertFalse(element("workspace-repository-search").exists, "The sheet repository search should not appear.")
        XCTAssertTrue(element("send-message-button").isEnabled, "A configured root allows a standalone message even when no repository is selected.")
        // With no repository, the empty state's + replaces the send-a-message prompt and opens the header's picker.
        let addRepositoryPrompt = element("empty-conversation-add-repository-button")
        XCTAssertTrue(addRepositoryPrompt.waitToExist(timeout: 10), "A task with no repository should show the add-repository + in its empty state.")
        XCTAssertEqual(accessibleLabelOrValue(of: addRepositoryPrompt), "Add repository")
        XCTAssertFalse(element("model-prompt").exists, "The add-repository prompt replaces the send-a-message prompt.")
        let plusFrame = addRepositoryPrompt.frame
        XCTAssertLessThan(abs(plusFrame.width - plusFrame.height), 2, "The add-repository + should be a standalone round button, not a capsule with its caption.")
        XCTAssertLessThan(plusFrame.width, 60, "The + should hold only its icon, not the explanation.")
        let addRepositoryCaption = element("empty-conversation-add-repository-caption")
        XCTAssertTrue(addRepositoryCaption.waitToExist(timeout: 5), "The + should be explained by a caption.")
        XCTAssertEqual(accessibleLabelOrValue(of: addRepositoryCaption), "Add repositories to the task's context")
        XCTAssertGreaterThanOrEqual(addRepositoryCaption.frame.minY, plusFrame.maxY, "The explanation should sit below the +, not beside it.")
        XCTAssertLessThan(abs(addRepositoryCaption.frame.midX - plusFrame.midX), 2, "The explanation should be centered under the +.")
        attachScreenshot(named: "Empty task shows the add-repository plus")
        attachElementScreenshot(element("empty-conversation"), named: "Add-repository plus and explanation close-up")
        addRepositoryPrompt.click()
        XCTAssertTrue(repositorySearch.waitToExist(timeout: 5), "Clicking the empty state's + should open the header's Add repository picker.")
        attachScreenshot(named: "Add-repository plus opens the Add repository picker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !repositorySearch.exists }, timeout: 5), "Escape should close the picker the empty state's + opened.")
        XCTAssertEqual(composer.value as? String, "Standalone draft", "Opening the picker from the empty state keeps the typed draft.")
        let shell = try XCTUnwrap(tasksFromBoardList().first)
        XCTAssertTrue((shell["workspaceRoots"] as? [String] ?? []).isEmpty, "New Task should persist an empty pending task before repository selection.")
        let shellID = try XCTUnwrap(shell["id"] as? String)

        _ = try runCLI(["task", "roots", "set", shellID, "--root", fixture.custom.path])
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Untitled task"].exists, "An empty conversation should keep its untitled title until the first prompt is added.")
        XCTAssertFalse(element("task-title-generating-loader").exists, "Title generation should not start before the first prompt.")
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertFalse(element("continue-response-button").exists)

        let createdTask = try XCTUnwrap(tasksFromBoardList().first)
        let createdTaskID = try XCTUnwrap(createdTask["id"] as? String)
        let newTaskEvents = try diagnosticEvents().filter {
            ["ui.new_task.started", "ui.new_task.succeeded"].contains($0["event"] as? String ?? "")
        }
        let newTaskStarted = try XCTUnwrap(newTaskEvents.first { $0["event"] as? String == "ui.new_task.started" })
        let newTaskSucceeded = try XCTUnwrap(newTaskEvents.first { $0["event"] as? String == "ui.new_task.succeeded" })
        let successAttemptID = try XCTUnwrap(newTaskStarted["attemptID"] as? String)
        XCTAssertFalse(successAttemptID.isEmpty)
        XCTAssertEqual(newTaskSucceeded["attemptID"] as? String, successAttemptID)
        XCTAssertEqual(newTaskSucceeded["taskID"] as? String, createdTaskID)
        XCTAssertNotNil(newTaskSucceeded["durationMilliseconds"] as? String)
        XCTAssertEqual(createdTask["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual(createdTask["workspaceRoots"] as? [String], [fixture.custom.path])
        let history = try runCLI(["conversation", "history", createdTaskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertNil(history?["diff"])

        // A typed draft keeps the task; back out of an empty pending conversation.
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertFalse(element("confirm-discard-empty-task-button").exists, "An empty new conversation should return to the board without a discard confirmation.")
        let deleted = try runCLI(["task", "get", createdTaskID], expectedStatus: 3)
        XCTAssertEqual((deleted["error"] as? [String: Any])?["code"] as? String, "not_found")
        attachScreenshot(named: "New conversation shows its empty state")
    }
    // case-contract: test_new_task_failure_diagnostics | A real directory at the task-store write-lock path makes CLI task creation fail with operation_failed and leaves no task persisted; the paired New Task button shows the save error and writes correlated start and failure diagnostics with the same attempt ID, error domain, and code.
    func test_new_task_failure_diagnostics() throws {
        launchApp(defaultParent: fixture.parent.path)
        let writeLock = dataDirectory.appendingPathComponent("store-write.lock", isDirectory: true)
        let missingLockTarget = dataDirectory.appendingPathComponent("missing-lock-parent/store-write.lock")
        try FileManager.default.createSymbolicLink(at: writeLock, withDestinationURL: missingLockTarget)

        element("new-task-button").click()
        let saveAlert = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        XCTAssertTrue(saveAlert.waitToExist(timeout: 10), "A real store-lock open failure should be shown to the user.")
        let alertTitle = saveAlert.staticTexts.matching(
            NSPredicate(format: "value == %@", "Couldn't save changes")
        ).firstMatch
        XCTAssertTrue(alertTitle.exists, "The store-lock failure sheet should identify the failed save.")
        let alertMessage = saveAlert.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Couldn't open the")
        ).firstMatch
        XCTAssertTrue(alertMessage.exists, "The store-lock failure sheet should explain the real lock-open error.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains { $0["event"] as? String == "ui.new_task.failed" }) ?? false
        }, timeout: 2), "The New Task failure should reach the diagnostics file promptly.")
        let events = try diagnosticEvents()
        let failure = try XCTUnwrap(events.last { $0["event"] as? String == "ui.new_task.failed" })
        let starts = events.filter { $0["event"] as? String == "ui.new_task.started" }
        let start = try XCTUnwrap(starts.last)
        let failureAttemptID = try XCTUnwrap(start["attemptID"] as? String)
        XCTAssertFalse(failureAttemptID.isEmpty)
        XCTAssertEqual(failure["attemptID"] as? String, failureAttemptID)
        XCTAssertFalse((failure["errorDomain"] as? String ?? "").isEmpty)
        XCTAssertFalse((failure["errorCode"] as? String ?? "").isEmpty)
        XCTAssertNotNil(failure["durationMilliseconds"] as? String)

        saveAlert.buttons["OK"].click()
        try FileManager.default.removeItem(at: writeLock)
        XCTAssertTrue(try tasksFromBoardList().isEmpty, "A failed create must not leave a persisted task.")
    }
    // case-contract: test_standalone_chat_legacy_hidden_task_migrates | A standalone chat left in the store as a hidden board task is converted once into its own model: it keeps its ID so the existing conversation transcript stays attached, keeps its provider session, carries its in-flight turn state across with the status message and progress report that explain it, is removed from the board so it never lists or resolves as a task, and reopening the chat returns that same migrated chat rather than creating a second one.
    func test_standalone_chat_legacy_hidden_task_migrates() throws {
        let legacyID = try seedLegacyStandaloneChatTask()
        launchApp(defaultParent: fixture.parent.path)

        // The board renders from its own SwiftData query, so this is where a leftover hidden
        // task would actually surface as a card.
        XCTAssertFalse(
            element("task-card-\(legacyID)").waitToExist(timeout: 3),
            "A chat migrated off the board must not render as a card."
        )
        XCTAssertTrue(try tasksFromBoardList().isEmpty, "The migrated chat must no longer be a board task.")
        assertCLIError(try runCLI(["task", "get", legacyID], expectedStatus: 3), code: "not_found")

        let opened = try runCLI(["chat", "open"])["result"] as? [String: Any]
        XCTAssertEqual(
            opened?["id"] as? String, legacyID,
            "The migrated chat must keep its ID so its existing transcript stays attached."
        )
        XCTAssertEqual(opened?["claudeSessionID"] as? String, "legacy-chat-session", "The chat's provider session must survive migration.")
        // The turn state must arrive with its explanation, not just the raw status.
        XCTAssertEqual(opened?["status"] as? String, "In Progress")
        XCTAssertEqual(opened?["statusMessage"] as? String, "Carried from the legacy chat task.")
        XCTAssertEqual(opened?["progressType"] as? String, "searching")
        XCTAssertEqual(opened?["progressLabel"] as? String, "Searching")
        XCTAssertEqual(opened?["progressDetail"] as? String, "Looking into volcanoes")

        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10), "The migrated chat should still open in the sidebar.")
        attachScreenshot(named: "Migrated standalone chat")

        let reopened = try runCLI(["chat", "open"])["result"] as? [String: Any]
        XCTAssertEqual(reopened?["id"] as? String, legacyID, "Migration must run once, not create a second chat.")
    }
    // case-contract: test_standalone_chat_separate_model_and_pages_round_trip | The Chat button opens the standalone chat — its own model rather than a board task — in a sliding sidebar that never appears on the board, task commands cannot reach it by ID, and the bridge rejects any attempt to add a repository or worktree root to it. The GUI composer works without a configured repository parent and omits task status, repository controls, the Changes sidebar, and the no-repository-selected banner. Its CLI page close-turn signal keeps a continuing reply on the active page and starts a new titled page on a topic change, a completed turn's user and assistant messages persist onto the active page without leaking onto other pages, and pages are findable by search. Each page is also stored in a separate atomic JSON file in a discoverable archive directory; pages already present before file archiving are backfilled once, and each file tracks current metadata and messages. A turn that omits close-turn is tracked as missed, then a background low-effort Luna fallback rejects one malformed classification and retries, moves both messages to its correctly titled page, keeps page evaluation visually quiet while the primary answer remains usable, then updates the transcript separator with the title when classification completes; a following send waits for that decision, and preserves chronological order on a later append. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes. Earlier pages stay visible in the transcript after their page session rotates, and a board task conversation rejects a chat page as turn context. While a chat turn is held active, queuing a follow-up on the chat resolves the chat rather than a board task and the queued message can be removed, and selecting the provider the chat already uses returns the chat unchanged instead of failing. The chat's own turn state changes (In Progress, then Waiting Response) during a send, and it never renders as a card on the visible Kanban board in any state. A chat turn that ran close-turn gets no nudge, and a Codex chat turn that skipped it gets exactly one nudge through the shared recovery loop, asking for close-turn on its reply and never for a task outcome, because the chat has no board status; its developer instructions teach it that task language means Playhouse's own board and give it the Playhouse task CLI, and they never ask it to write the page title into its visible answer. Opening a board task while the chat sidebar is showing replaces it with that task's conversation view instead of showing both at once, and returning to the board reveals the chat sidebar again, with the chat's own model left untouched by the unrelated task. The visible chat panel opens at full board-content height, overlaps the logo header and narrow board sidebar, and hides the covered branding and sidebar controls from accessibility navigation while open; it raises the board's minimum width by the chat panel width, so the window grows to keep the shifted columns visible; it pushes the columns to the panel’s right edge; closing chat reveals the sidebar while the window keeps its grown width, and the columns center in the board, now wider than they are. Dragging the chat sidebar's right border resizes it, between a 320-point minimum and the larger of its default width and the screen width the board's minimum width leaves free, and reopening the sidebar, even after an app relaunch, keeps the dragged width. The border's grab strip extends only out over the board, never over the transcript's scroller along its inner side, so pressing and dragging just inside the border leaves the width unchanged; hovering the border shows the left-right resize cursor, and hovering just inside it does not. While the edge moves, the chat keeps the width it was last laid out at, clipped to the panel, and its transcript reflows to the panel's width when the drag ends.
    func test_standalone_chat_separate_model_and_pages_round_trip() throws {
        let fixtureSource = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureSource.path), "The prepared Codex fixture is missing or not executable.")
        // The `.hold-release` marker holds the one turn that needs it; a `-hold-release` name
        // would hold every later turn too, including the GUI send the classifier waits on.
        let chatFixtureExecutable = dataDirectory.appendingPathComponent("codex-fixture-chat-unique-turns-success")
        try copyFixtureFile(at: fixtureSource, to: chatFixtureExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chatFixtureExecutable.path)
        // Without the owner marker the app ignores this copy and falls back to the installed Codex CLI.
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = chatFixtureExecutable.path
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("chat-sidebar-button").exists, "The board header should offer a Chat button next to New Task.")
        XCTAssertFalse(element("chat-sidebar").exists, "The chat sidebar should be closed by default.")

        let boardHeader = element(withAccessibilityLabel: "Kanban header")
        let boardSidebar = element(withAccessibilityLabel: "Kanban sidebar")
        let backlogColumn = element("column-backlog")
        let reviewColumn = element("column-review")
        let mainWindow = app.windows.firstMatch
        let windowFrameBeforeOpeningChat = mainWindow.frame
        let headerFrameBeforeOpeningChat = boardHeader.frame
        let sidebarFrameBeforeOpeningChat = boardSidebar.frame
        let backlogColumnFrameBeforeOpeningChat = backlogColumn.frame

        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10), "Clicking Chat should slide in the sidebar.")
        XCTAssertTrue(
            waitUntil({ mainWindow.frame.width > windowFrameBeforeOpeningChat.width + 1 }, timeout: 5),
            "Opening chat should grow the window to fit the columns beside the chat."
        )
        XCTAssertTrue(reviewColumn.waitToExist(timeout: 5), "The rightmost review column should remain present after the window grows.")
        let columnsViewport = element("board-columns-scroll-view")
        // Read the geometry once the slide-in and window growth have settled.
        XCTAssertTrue(
            waitUntil({
                let review = reviewColumn.frame
                let viewport = columnsViewport.frame
                return review.width >= 260 && review.minX >= viewport.minX
                    && review.maxX <= viewport.maxX && review.maxX <= mainWindow.frame.maxX
            }, timeout: 5),
            "Growing the window should keep the rightmost board column fully inside the board viewport and window."
        )
        let chatFrame = element("chat-sidebar").frame
        XCTAssertLessThanOrEqual(chatFrame.minY, headerFrameBeforeOpeningChat.minY, "The full-height chat panel should begin at the top of the logo header.")
        XCTAssertEqual(chatFrame.maxY, sidebarFrameBeforeOpeningChat.maxY, accuracy: 1, "The chat panel should extend to the bottom of the board content.")
        XCTAssertFalse(element(withAccessibilityLabel: "Kanban sidebar").exists, "The covered board sidebar should not remain in accessibility navigation while chat is open.")
        XCTAssertFalse(app.images["Playhouse logo"].exists, "The covered logo should not remain in accessibility navigation while chat is open.")
        XCTAssertTrue(chatFrame.contains(sidebarFrameBeforeOpeningChat), "The open chat panel should cover the board sidebar.")
        XCTAssertGreaterThan(
            backlogColumn.frame.minX,
            backlogColumnFrameBeforeOpeningChat.minX,
            "Opening chat should push the board columns to the right."
        )
        XCTAssertGreaterThanOrEqual(
            backlogColumn.frame.minX,
            chatFrame.maxX,
            "The board columns should begin at or to the right of the chat panel."
        )
        let backlogColumnFrameWhileChatOpen = backlogColumn.frame
        let reviewColumnFrame = reviewColumn.frame
        let columnsViewportFrame = columnsViewport.frame
        XCTAssertGreaterThanOrEqual(reviewColumnFrame.width, 260, "The review column should be fully visible rather than clipped by the scroll viewport.")
        XCTAssertGreaterThanOrEqual(reviewColumnFrame.minX, columnsViewportFrame.minX, "The review column should begin within the board viewport.")
        XCTAssertLessThanOrEqual(reviewColumnFrame.maxX, columnsViewportFrame.maxX, "The review column should end within the board viewport.")
        XCTAssertLessThanOrEqual(
            reviewColumnFrame.maxX,
            mainWindow.frame.maxX,
            "Growing the window should keep the rightmost board column inside the visible window."
        )
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10), "The sidebar should reuse the standard chat composer.")
        XCTAssertFalse(element("task-status-message").exists, "Standalone chat must not show task status.")
        XCTAssertFalse(app.staticTexts["Backlog"].exists, "Standalone chat must not show a board status label.")
        XCTAssertFalse(element("conversation-repository-search").exists, "Standalone chat must not show repository controls.")
        XCTAssertFalse(element("add-conversation-repository-button").exists, "Standalone chat must not expose Add repository.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation-repository-badge-")).count, 0, "Standalone chat must not show repository badges.")
        XCTAssertFalse(element("workspace-changes-list").exists, "Standalone chat must not mount the task Changes sidebar.")
        XCTAssertFalse(element("workspace-changes-empty").exists, "Standalone chat must not show task workspace changes.")
        // Anchor on the rendered placeholder first: while history loads neither it nor the
        // title exists, so an unanchored absence check would pass even without the fix.
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10), "The standalone chat should show its empty-conversation placeholder.")
        XCTAssertTrue(element("model-prompt").exists, "The placeholder should keep its send-a-message prompt.")
        XCTAssertFalse(element("empty-conversation-add-repository-button").exists, "Standalone chat must not offer the add-repository +.")
        XCTAssertFalse(element("empty-conversation-repository-title").exists, "Standalone chat must not show the no-repository-selected banner.")
        attachScreenshot(named: "Standalone chat sidebar opened")

        // Dragging the sidebar's right border resizes it, within limits, and the width is remembered.
        let chatSidebar = element("chat-sidebar")
        let chatHandle = element("chat-sidebar-resize-handle")
        XCTAssertTrue(chatHandle.waitToExist(timeout: 5))
        // The handle's grab strip starts at the sidebar's 1-point border and extends out over the board.
        let chatWidth = { chatHandle.frame.minX + 1 - chatSidebar.frame.minX }
        XCTAssertEqual(chatWidth(), 460, accuracy: 2, "The resize handle is the sidebar's right border.")
        let chatWidthBefore = chatWidth()
        // The transcript's scroller runs along the border's inner side, so the grab strip must not reach inside the
        // chat: pressing there and dragging leaves the width alone (and the pointer is not a resize pointer).
        let chatTranscript = chatSidebar.descendants(matching: .any).matching(identifier: "conversation-scroll-view").firstMatch
        XCTAssertTrue(chatTranscript.exists, "The chat transcript should be present beside its resize border.")
        XCTAssertGreaterThanOrEqual(chatHandle.frame.minX, chatTranscript.frame.maxX - 1, "The resize strip must not overlap the transcript's scroller: handle=\(chatHandle.frame), transcript=\(chatTranscript.frame)")
        let insideBorder = chatHandle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -5, dy: 0))
        app.activate()
        restPointer(on: chatHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(waitUntil({ self.systemCursorIsColumnResize() }, timeout: 3), "Hovering the chat's border should show the resize cursor: \(systemCursorDescription())")
        restPointer(on: insideBorder)
        XCTAssertTrue(waitUntil({ !self.systemCursorIsColumnResize() }, timeout: 3), "Just inside the border, over the transcript, the pointer is not a resize pointer: \(systemCursorDescription())")
        insideBorder.press(forDuration: 0.2, thenDragTo: insideBorder.withOffset(CGVector(dx: -60, dy: 0)))
        XCTAssertFalse(waitUntil({ abs(chatWidth() - chatWidthBefore) > 1 }, timeout: 0.5), "Dragging over the transcript's scroller must not resize the chat: \(chatWidth())")
        // While the edge moves, the chat keeps the width it was last laid out at and the panel clips it; once a drag
        // ends, the transcript must have reflowed to the panel, ending the same distance from the border as before.
        let transcriptGapToBorder = { chatHandle.frame.minX + 1 - chatTranscript.frame.maxX }
        let restingTranscriptGap = transcriptGapToBorder()
        let chatContentFillsPanel = { chatTranscript.exists && abs(transcriptGapToBorder() - restingTranscriptGap) <= 2 }
        attachScreenshot(named: "Standalone chat keeps its width after a drag over the transcript scroller")
        let chatHandleCenter = { chatHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: -60, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - (chatWidthBefore - 60)) <= 6 }, timeout: 5), "Dragging left narrows the chat: \(chatWidth())")
        let chatNarrowed = chatWidth()
        attachScreenshot(named: "Standalone chat narrowed by dragging its right border")
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: -900, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - 320) <= 3 }, timeout: 5), "The chat stops at its minimum width: \(chatWidth())")
        XCTAssertTrue(waitUntil(chatContentFillsPanel, timeout: 5), "The narrowed chat's transcript reflows to the panel once the drag ends: transcript=\(chatTranscript.frame), handle=\(chatHandle.frame)")
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: chatNarrowed - 320, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - chatNarrowed) <= 6 }, timeout: 5), "Dragging right widens the chat again: \(chatWidth())")
        // The chat widens only until it and the board's 980-point minimum fill the screen, and never below its 460-point default.
        // The drag spans the whole screen so it reaches that limit on any screen size.
        let screenWidth = app.menuBars.firstMatch.frame.width
        let expectedMaximum = max(460, screenWidth - 980)
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: screenWidth, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - expectedMaximum) <= 6 }, timeout: 5), "Dragging far right stops at \(expectedMaximum) on a \(screenWidth)-point screen: \(chatWidth())")
        XCTAssertTrue(waitUntil(chatContentFillsPanel, timeout: 5), "The widened chat's transcript reflows to the panel once the drag ends: transcript=\(chatTranscript.frame), handle=\(chatHandle.frame)")
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: chatNarrowed - expectedMaximum, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - chatNarrowed) <= 6 }, timeout: 5), "Dragging back narrows the chat again: \(chatWidth())")
        refreshStandaloneChatSidebar()
        XCTAssertTrue(waitUntil({ chatSidebar.exists && abs(chatWidth() - chatNarrowed) <= 6 }, timeout: 5), "Reopening after a relaunch keeps the dragged width: \(chatWidth())")
        XCTAssertTrue(waitUntil(chatContentFillsPanel, timeout: 5), "The reopened chat's transcript fills its remembered width: transcript=\(chatTranscript.frame), handle=\(chatHandle.frame)")
        attachScreenshot(named: "Standalone chat reopened at its dragged width with the transcript reflowed")
        // The rest of the case asserts exact header positions at the default width. Dragging to the far right clamps to the
        // cap, which is exactly the default when the screen has no spare width; a hand-measured drag would leave a fractional width.
        chatHandleCenter().press(forDuration: 0.2, thenDragTo: chatHandleCenter().withOffset(CGVector(dx: screenWidth, dy: 0)))
        XCTAssertTrue(waitUntil({ abs(chatWidth() - expectedMaximum) <= 6 }, timeout: 5), "Dragging far right again stops at the cap: \(chatWidth())")

        XCTAssertTrue(try tasksFromBoardList().isEmpty, "The standalone chat must never appear on the board.")

        let coveringTask = try runCLI(
            ["task", "create", "--title", "Covers standalone chat", "--prompt", "Fixture task description.", "--repo", fixture.primary.path]
        )["result"] as? [String: Any]
        let coveringTaskID = try XCTUnwrap(coveringTask?["id"] as? String)
        let coveringCard = element("task-card-\(coveringTaskID.uppercased())")
        XCTAssertTrue(waitUntil({ coveringCard.exists }, timeout: 10), "The new task should appear on the board behind the open chat sidebar.")
        clickTaskCardTitle(coveringCard)
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10), "Opening a task should show its conversation view.")
        XCTAssertFalse(element("chat-sidebar").exists, "Entering a task must cover the standalone chat, not show both at once.")
        attachScreenshot(named: "Task view covers standalone chat sidebar")

        element("back-to-board-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10), "Leaving the task should reveal the standalone chat sidebar again.")

        let opened = try runCLI(["chat", "open"])["result"] as? [String: Any]
        let chatTaskID = try XCTUnwrap(opened?["id"] as? String)
        XCTAssertEqual(opened?["title"] as? String, "Chat")
        XCTAssertEqual((opened?["repositoryWorktrees"] as? [Any])?.count, 0)

        // The chat is its own model, not a task, so task commands cannot reach it by ID.
        assertCLIError(try runCLI(["task", "get", chatTaskID], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["task", "move", chatTaskID, "Done"], expectedStatus: 3), code: "not_found")

        let kyoto = try XCTUnwrap(
            (try runCLI(["chat", "page", "new", "--title", "Trip to Kyoto"])["result"] as? [String: Any])?["page"] as? [String: Any]
        )
        let continued = try XCTUnwrap(
            (try runCLI(["chat", "page", "close-turn", chatTaskID, "--continues", "true"])["result"] as? [String: Any])?["page"] as? [String: Any]
        )
        XCTAssertEqual(continued["id"] as? String, kyoto["id"] as? String, "Continuing must append to the already-active page.")

        let recipes = try XCTUnwrap(
            (try runCLI(["chat", "page", "close-turn", chatTaskID, "--continues", "false", "--new-title", "Dinner recipes"])["result"] as? [String: Any])?["page"] as? [String: Any]
        )
        XCTAssertNotEqual(recipes["id"] as? String, kyoto["id"] as? String, "A topic change must start a new page.")

        _ = try runCLI(["chat", "page", "close-turn", chatTaskID, "--continues", "false"], expectedStatus: 2)

        let pageListing = try XCTUnwrap(try runCLI(["chat", "page", "list"])["result"] as? [String: Any])
        let archiveDirectory = URL(fileURLWithPath: try XCTUnwrap(pageListing["archiveDirectory"] as? String))
        XCTAssertEqual(archiveDirectory.standardizedFileURL, dataDirectory.appendingPathComponent("StandaloneChat-Pages", isDirectory: true).standardizedFileURL)
        let kyotoFile = archiveDirectory.appendingPathComponent("\(try XCTUnwrap(kyoto["id"] as? String)).json")
        let recipesFile = archiveDirectory.appendingPathComponent("\(try XCTUnwrap(recipes["id"] as? String)).json")
        XCTAssertNotEqual(kyotoFile, recipesFile, "Each page must have its own filesystem file.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kyotoFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recipesFile.path))
        // Recreate the pre-archive database state so opening the manager proves
        // it backfills pages that existed before the one-time file migration.
        var archiveDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dataDirectory.appendingPathComponent("StandaloneChat-v1.sqlite").path, &archiveDatabase), SQLITE_OK)
        guard let archiveDatabase else { XCTFail("Could not open the standalone chat database for migration setup."); return }
        let markerStatus = sqlite3_exec(archiveDatabase, "DELETE FROM chat_archive_migrations WHERE version = 1;", nil, nil, nil)
        sqlite3_close(archiveDatabase)
        XCTAssertEqual(markerStatus, SQLITE_OK, "Could not reset the page archive migration marker.")
        try FileManager.default.removeItem(at: kyotoFile)
        _ = try runCLI(["chat", "page", "list"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kyotoFile.path), "Opening a pre-archive database should backfill missing page files once.")
        let matches = try XCTUnwrap(
            (try runCLI(["chat", "page", "search", "Kyoto"])["result"] as? [String: Any])?["matches"] as? [[String: Any]]
        )
        XCTAssertTrue(
            matches.contains { (($0["page"] as? [String: Any])?["id"] as? String) == kyoto["id"] as? String },
            "Searching the old page's title should find it even after a newer page is active."
        )

        // Drive one real provider turn and verify the user/assistant text actually lands on
        // the active page via chat page read, and does not leak onto an unrelated page.
        try Data().write(to: URL(fileURLWithPath: chatFixtureExecutable.path + ".hold-release"))
        let holdMarker = URL(fileURLWithPath: chatFixtureExecutable.path + ".hold-release")
        let activeMarker = URL(fileURLWithPath: chatFixtureExecutable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: chatFixtureExecutable.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)

        let sendProcess = Process()
        sendProcess.executableURL = cliURL
        sendProcess.arguments = ["conversation", "send", chatTaskID, "--message", "What's a good side dish?"]
        var sendEnvironment = ProcessInfo.processInfo.environment
        sendEnvironment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        sendEnvironment["CODEX_HOME"] = dataDirectory.appendingPathComponent("codex-home").path
        sendEnvironment["PLAYHOUSE_WORKTREE_LABEL"] = "Playhouse UI Test Worktree"
        sendEnvironment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        sendEnvironment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        sendEnvironment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = chatFixtureExecutable.path
        sendProcess.environment = sendEnvironment
        let sendStdout = Pipe()
        let sendStderr = Pipe()
        sendProcess.standardOutput = sendStdout
        sendProcess.standardError = sendStderr
        try sendProcess.run()
        defer {
            if sendProcess.isRunning {
                try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                sendProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The fixture should hold the standalone chat turn open for a close-turn report.")
        // Queuing is a conversation action, so it must resolve the chat rather than look for a
        // board task. The turn is held active here, which is exactly when a follow-up queues.
        let queuedInChat = try XCTUnwrap(
            try runCLI(["conversation", "queue", chatTaskID, "--message", "Queue this for after the chat turn."])["result"] as? [String: Any]
        )
        XCTAssertEqual(queuedInChat["text"] as? String, "Queue this for after the chat turn.")
        XCTAssertEqual(queuedInChat["taskID"] as? String, chatTaskID)
        _ = try runCLI(["conversation", "queue-remove", chatTaskID, try XCTUnwrap(queuedInChat["id"] as? String)])
        // Selecting the provider the chat already uses is a no-op that must return the chat.
        let unchangedProvider = try XCTUnwrap(
            try runCLI(["conversation", "provider", chatTaskID, "set", "codex"])["result"] as? [String: Any]
        )
        XCTAssertEqual(unchangedProvider["id"] as? String, chatTaskID)
        XCTAssertEqual(unchangedProvider["conversationProvider"] as? String, "codex")
        _ = try runCLI(["chat", "page", "close-turn", chatTaskID, "--continues", "true"])
        try "Release the completed fixture turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        sendProcess.waitUntilExit()
        XCTAssertEqual(sendProcess.terminationStatus, 0, "The standalone chat turn should complete successfully.")
        try? FileManager.default.removeItem(at: holdMarker)

        // A send moves the chat's own turn state away from Backlog (In Progress, then Waiting
        // Response). That state used to live on a hidden BoardTask, which is how the chat leaked
        // onto the board: it renders from SwiftUI's own @Query over BoardTask, not the board.list
        // CLI path that tasksFromBoardList() checks. The chat is no longer a BoardTask at all, so
        // confirm the rendered board still has no card for it in that state.
        XCTAssertFalse(
            element("task-card-\(chatTaskID)").exists,
            "The standalone chat must never render as a card on the visible Kanban board."
        )

        // A chat turn that ran close-turn is settled, so no nudge follows it.
        let chatFixtureHistory = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: chatFixtureExecutable.path + ".history"))
            ) as? [String: Any]
        )
        let chatFixtureTurns = try XCTUnwrap(chatFixtureHistory["turns"] as? [[String: Any]])
        XCTAssertFalse(chatFixtureTurns.isEmpty, "The chat fixture should have recorded its turns.")
        XCTAssertFalse(
            chatFixtureTurns.contains { (($0["userMessage"] as? String) ?? "").lowercased().contains("playhouse internal outcome nudge:") },
            "A standalone chat turn that ran close-turn must not get a nudge."
        )
        // The chat must know it is Playhouse's own chat and own the board through the CLI,
        // instead of reaching for an unrelated task tool that the user can never see.
        let chatInstructions = (chatFixtureHistory["threadStartDeveloperInstructions"] as? String) ?? ""
        XCTAssertTrue(chatInstructions.contains("task create"), "The chat must be taught the Playhouse task CLI.")
        XCTAssertTrue(chatInstructions.contains("they always mean Playhouse"))
        XCTAssertTrue(chatInstructions.contains("`task create` requires --prompt"), "The chat must create tasks with a full description.")
        // Its capabilities come from the CLI's own help, never from a copied command list that
        // drifts from the CLI, and it may call something impossible only after checking help.
        XCTAssertTrue(chatInstructions.contains("\(cliURL.path)' help --for chat"), "The chat must be sent to the CLI's own help.")
        XCTAssertTrue(chatInstructions.contains("Say that something isn't possible only after its help shows no command for it."))
        XCTAssertFalse(chatInstructions.contains("task create --title \"<title>\""))
        XCTAssertFalse(chatInstructions.contains("say so plainly"))
        XCTAssertTrue(chatInstructions.contains("Never start, move or schedule a task unless the user asks you to"))
        XCTAssertTrue(chatInstructions.contains("Before you delete anything, such as a task, skill, rule or MCP server, confirm with the user."))
        // Page titles reach the user as transcript separators, parsed from close-turn.
        // Assert the prohibition positively too: pinning only the old wording would let the
        // instruction come back phrased differently.
        XCTAssertTrue(chatInstructions.contains("never write the page name"))
        XCTAssertFalse(chatInstructions.contains("Page: <current page title>"))

        let recipesArchive = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: recipesFile)) as? [String: Any]
        )
        XCTAssertEqual((recipesArchive["page"] as? [String: Any])?["title"] as? String, "Dinner recipes")
        XCTAssertTrue(
            (recipesArchive["messages"] as? [[String: Any]])?.contains {
                ($0["role"] as? String) == "user" && ($0["text"] as? String) == "What's a good side dish?"
            } == true,
            "The completed user turn should be written to its page file before any later page read."
        )
        let recipesMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(recipes["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertTrue(
            recipesMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == "What's a good side dish?" },
            "The user's message should be persisted on the page the agent's close-turn call selected."
        )
        XCTAssertTrue(
            recipesMessages.contains { ($0["role"] as? String) == "assistant" && !(($0["text"] as? String) ?? "").isEmpty },
            "The assistant's reply should also be persisted on that page."
        )
        let recipesRead = try XCTUnwrap(try runCLI(["chat", "page", "read", try XCTUnwrap(recipes["id"] as? String)])["result"] as? [String: Any])
        XCTAssertEqual(recipesRead["filePath"] as? String, recipesFile.path)
        XCTAssertEqual(
            (recipesArchive["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String },
            recipesMessages.compactMap { $0["text"] as? String },
            "The page file should stay synchronized with its persisted transcript."
        )
        let kyotoMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(kyoto["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertTrue(kyotoMessages.isEmpty, "Messages from the recipes turn must not leak onto an unrelated page.")

        let compliantStatus = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        XCTAssertEqual(compliantStatus["missedPreviousPageSignal"] as? Bool, false, "A turn that called close-turn must not be flagged as missed.")

        assertCLIError(
            try runCLI(["task", "repository", "add", chatTaskID, "--repo", fixture.primary.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        _ = try runCLI(["settings", "clear-parent"])
        XCTAssertNil((try runCLI(["settings", "get"])["result"] as? [String: Any])?["defaultParentFolder"] as? String)

        // Exercise the actual sidebar composer without a default repository root. The
        // background fallback must update the visible page title after the GUI send returns.
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        let classifierHold = URL(fileURLWithPath: chatFixtureExecutable.path + ".hold-classifier")
        let classifierActive = URL(fileURLWithPath: chatFixtureExecutable.path + ".classifier-active")
        let classifierRelease = URL(fileURLWithPath: chatFixtureExecutable.path + ".classifier-release")
        try Data().write(to: classifierHold)
        element("message-composer").click()
        element("message-composer").typeText("Tell me about Saturn's rings")
        XCTAssertTrue(element("send-message-button").isEnabled, "Standalone chat should send without a configured repository root.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: classifierActive.path) }, timeout: 15), "The fallback classifier should run after the primary answer and be held independently.")
        // The same shared recovery loop nudges a Codex chat turn that skipped close-turn: once,
        // for the page signal, never for a task outcome.
        let codexNudges = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: chatFixtureExecutable.path + ".history"))) as? [String: Any])?["turns"] as? [[String: Any]]
        ).compactMap { $0["userMessage"] as? String }.filter { $0.lowercased().contains("playhouse internal outcome nudge:") }
        XCTAssertEqual(codexNudges.count, 1, "A Codex chat turn that skipped close-turn gets exactly one nudge.")
        XCTAssertTrue(codexNudges.first?.contains("chat page close-turn \(chatTaskID)") == true)
        XCTAssertFalse(codexNudges.first?.contains("task outcome") ?? true)
        try assertAutomaticMessageBubble(taskID: chatTaskID, containing: "This is the only reminder for that reply.")
        XCTAssertFalse(element("codex-chat-error").exists, "The Codex chat nudge turn completes without an error.")
        XCTAssertFalse(element("chat-active-page-title").exists, "Page titles should appear in transcript separators, not the header.")
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists, "Page evaluation should stay visually quiet while pending.")
        XCTAssertEqual(element("chat-sidebar").descendants(matching: .progressIndicator).count, 0, "Page evaluation should not show a loader in the chat sidebar.")
        XCTAssertTrue(transcriptMessage("Answers received: Blue / fixture-secret.").waitToExist(timeout: 10), "The primary answer should render before the background classifier is released.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "The background classifier must not keep the chat turn running.")
        XCTAssertTrue(chatPageSeparatorIsVisible("Dinner recipes"), "The current title should remain in its transcript separator until classification completes.")
        element("message-composer").click()
        element("message-composer").typeText("One more thought about Saturn")
        element("send-message-button").click()
        XCTAssertFalse(
            waitUntil({ self.fixtureTurnCount(chatFixtureExecutable, containing: "One more thought about Saturn") > 0 }, timeout: 3),
            "A new send should queue behind the held fallback decision."
        )
        try Data("Release classifier.\n".utf8).write(to: classifierRelease)
        let fallbackReady = waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any],
                  page["title"] as? String == "Saturn Rings",
                  let pageID = page["id"] as? String,
                  let messages = (try? self.runCLI(["chat", "page", "read", pageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] else { return false }
            return self.chatPageSeparatorIsVisible("Saturn Rings")
                && messages.compactMap { $0["text"] as? String } == [
                    "Tell me about Saturn's rings", "Answers received: Blue / fixture-secret.",
                    "One more thought about Saturn", "Answers received: Blue / fixture-secret.",
                ]
        }, timeout: 30)
        XCTAssertTrue(fallbackReady, "The background fallback should update the active page title and clear the missed-signal warning.")
        XCTAssertFalse(element("chat-active-page-title").exists, "The page title should remain in the transcript, not the header.")
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists, "The warning should disappear after the fallback persists its result.")
        let fallbackStatus = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        let fallbackPage = try XCTUnwrap(fallbackStatus["activePage"] as? [String: Any])
        let fallbackMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(fallbackPage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertTrue(
            fallbackMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == "Tell me about Saturn's rings" },
            "The fallback-classified turn's messages should be moved onto its new page."
        )
        XCTAssertTrue(
            fallbackMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "Answers received: Blue / fixture-secret." },
            "The assistant reply must move with its user message onto the new page."
        )
        let priorPageMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(recipes["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        // The fixture answers every turn with the same text, so the moved turn is identified
        // by its turn ID: none of its messages, user or assistant, may remain on the prior page.
        let movedTurnID = try XCTUnwrap(
            fallbackMessages.first { ($0["role"] as? String) == "user" && ($0["text"] as? String) == "Tell me about Saturn's rings" }?["turnID"] as? String
        )
        XCTAssertFalse(
            priorPageMessages.contains { ($0["turnID"] as? String) == movedTurnID },
            "The fallback-classified turn must not remain duplicated on the prior page."
        )

        // A later turn was queued while the first fallback was held; both turns must
        // now appear in order on the fallback-selected page.
        let orderedMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(fallbackPage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertEqual(orderedMessages.map { $0["text"] as? String }, [
            "Tell me about Saturn's rings", "Answers received: Blue / fixture-secret.",
            "One more thought about Saturn", "Answers received: Blue / fixture-secret.",
        ], "A later appended turn must follow the moved messages in chronological order.")
        let fixtureHistory = try Data(contentsOf: URL(fileURLWithPath: chatFixtureExecutable.path + ".history"))
        let fixtureTurns = try XCTUnwrap((try JSONSerialization.jsonObject(with: fixtureHistory) as? [String: Any])?["turns"] as? [[String: Any]])
        let classifierTurns = fixtureTurns.filter { ($0["userMessage"] as? String)?.hasPrefix("Classify the latest user message for Playhouse's continuous chat page index.") == true }
        XCTAssertEqual(classifierTurns.count, 3, "The fallback should reject one malformed result, retry once, then classify the later turn.")
        let classifierTurn = try XCTUnwrap(classifierTurns.last)
        XCTAssertEqual(classifierTurn["modelID"] as? String, "gpt-6-luna", "The Codex fallback should use Luna.")
        XCTAssertEqual(classifierTurn["reasoningEffort"] as? String, "low", "The background classifier should use low effort.")

        // An explicit page start supersedes a held classifier. Reopen the sidebar
        // to refresh its persisted status, then ensure the late result stays stale.
        let priorPageID = try XCTUnwrap(fallbackPage["id"] as? String)
        try? FileManager.default.removeItem(at: classifierActive)
        try? FileManager.default.removeItem(at: classifierRelease)
        // Hold only Neptune's classifier: a generic hold is taken by whichever classifier runs
        // next, which can be the previous turn's still-running decision.
        try Data().write(to: URL(fileURLWithPath: chatFixtureExecutable.path + ".hold-neptune-classifier"))
        element("message-composer").click()
        element("message-composer").typeText("Tell me about Neptune")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: classifierActive.path) }, timeout: 15))
        let explicitPage = try XCTUnwrap((try runCLI(["chat", "page", "new", "--title", "Explicit topic"])["result"] as? [String: Any])?["page"] as? [String: Any])
        refreshStandaloneChatSidebar()
        // A page's title separator is drawn before its first message, so the new page shows
        // once a turn lands on it (asserted after the Mars send below).
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists)
        try Data("Release classifier.\n".utf8).write(to: classifierRelease)
        XCTAssertTrue(waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  let page = status["activePage"] as? [String: Any] else { return false }
            return (page["id"] as? String) == (explicitPage["id"] as? String)
        }, timeout: 30), "The late classifier must not replace the explicit page.")
        let explicitMessages = try XCTUnwrap((try runCLI(["chat", "page", "read", try XCTUnwrap(explicitPage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(explicitMessages.isEmpty)
        let oldPageMessages = try XCTUnwrap((try runCLI(["chat", "page", "read", priorPageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(oldPageMessages.contains { ($0["text"] as? String) == "Tell me about Neptune" })
        XCTAssertTrue(oldPageMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "Answers received: Blue / fixture-secret." })

        let classifierFailure = URL(fileURLWithPath: chatFixtureExecutable.path + ".fail-classifier")
        try Data().write(to: classifierFailure)
        element("message-composer").click()
        element("message-composer").typeText("Tell me about Mars")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["chat", "status"])["result"] as? [String: Any])?["missedPreviousPageSignal"] as? Bool == true
        }, timeout: 30), "Malformed helper results should keep the pending decision visible and durable.")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Explicit topic") }, timeout: 10), "The explicit page's title should appear with its first message.")
        XCTAssertFalse(element("chat-active-page-title").exists, "Unresolved classification should not add a page title to the header.")
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists, "Unresolved classification should remain visually quiet.")
        XCTAssertEqual(element("chat-sidebar").descendants(matching: .progressIndicator).count, 0, "Unresolved classification should not show a loader.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "The Mars turn should finish before the next send.")
        element("message-composer").click()
        element("message-composer").typeText("Do not overtake Mars")
        element("send-message-button").click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 15), "A later send should explain that the prior page decision is still pending.")
        let failedHistory = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: chatFixtureExecutable.path + ".history"))) as? [String: Any]
        let failedTurns = try XCTUnwrap(failedHistory?["turns"] as? [[String: Any]])
        XCTAssertFalse(failedTurns.contains { ($0["userMessage"] as? String) == "Do not overtake Mars" }, "The blocked follow-up must not reach the provider.")
        try FileManager.default.removeItem(at: classifierFailure)
        _ = try runCLI(["chat", "status"])
        let retryStatus = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        XCTAssertFalse(retryStatus["missedPreviousPageSignal"] as? Bool ?? true)
        XCTAssertEqual((retryStatus["activePage"] as? [String: Any])?["title"] as? String, "Mars")
        refreshStandaloneChatSidebar()
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Mars") }, timeout: 10))
        XCTAssertFalse(element("chat-active-page-title").exists, "The resolved title should remain in the transcript, not the header.")
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists)
        element("message-composer").click()
        element("message-composer").typeKey("a", modifierFlags: .command)
        element("message-composer").typeText("Another thought about Mars")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any],
                  page["title"] as? String == "Mars",
                  let pageID = page["id"] as? String,
                  let messages = (try? self.runCLI(["chat", "page", "read", pageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] else { return false }
            return messages.contains { ($0["text"] as? String) == "Another thought about Mars" }
        }, timeout: 30), "A new send should work once the pending page decision has recovered.")

        // Page sessions rotate, so earlier pages must stay visible rather than disappearing.
        XCTAssertTrue(revealWholeTranscript(), "The reopened chat should load its earlier pages as the reader scrolls up.")
        // Earlier pages render only near the viewport, so scroll to them as a reader would.
        let dinnerSeparator = element("chat-sidebar")
            .descendants(matching: .scrollView)
            .matching(identifier: "conversation-scroll-view")
            .firstMatch
            .staticTexts
            .matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "chat-page-separator", "Dinner recipes", "Dinner recipes"))
            .firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(dinnerSeparator), "An earlier page stays visible after its session rotated.")
        XCTAssertTrue(
            scrollTranscriptUntilExists(element("chat-sidebar").groups["What's a good side dish?"]),
            "An earlier page keeps its messages in the chat transcript."
        )
        let boardTask = try XCTUnwrap(
            (try runCLI(["task", "create", "--title", "Context page rejection", "--prompt", "Fixture task description."])["result"] as? [String: Any])?["id"] as? String
        )
        let activePageID = try XCTUnwrap(
            ((try runCLI(["chat", "status"])["result"] as? [String: Any])?["activePage"] as? [String: Any])?["id"] as? String
        )
        assertCLIError(
            try runCLI(["conversation", "send", boardTask, "--message", "Hello", "--context-page", activePageID], expectedStatus: 2),
            code: "invalid_argument"
        )

        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ !element("chat-sidebar").exists }, timeout: 5), "Returning to the board should slide the chat sidebar away.")
        // As before the board sidebar existed, the window keeps the width it grew to.
        XCTAssertGreaterThan(mainWindow.frame.width, windowFrameBeforeOpeningChat.width + 1, "Closing chat should keep the window's grown width.")
        XCTAssertEqual(boardHeader.frame.origin, headerFrameBeforeOpeningChat.origin, "Closing chat should leave the logo header in place.")
        XCTAssertEqual(boardHeader.frame.height, headerFrameBeforeOpeningChat.height, "Closing chat should leave the logo header's height unchanged.")
        XCTAssertTrue(element(withAccessibilityLabel: "Kanban sidebar").waitToExist(timeout: 5), "Closing chat should restore the board sidebar to accessibility navigation.")
        XCTAssertTrue(app.images["Playhouse logo"].exists, "Closing chat should restore the logo to accessibility navigation.")
        // The sidebar's frame keeps settling for a moment after the chat slides away.
        XCTAssertTrue(
            waitUntil({ boardSidebar.frame == sidebarFrameBeforeOpeningChat }, timeout: 5),
            "Closing chat should reveal the sidebar in its original position: \(boardSidebar.frame) vs \(sidebarFrameBeforeOpeningChat)."
        )
        // The kept width leaves the board wider than its columns, so they center in it
        // rather than return to their original x beside the sidebar.
        XCTAssertGreaterThan(columnsViewport.frame.width, 948 + 100, "The kept width should leave the board wider than its columns and margins: board=\(columnsViewport.frame).")
        XCTAssertTrue(
            waitUntil({
                let leadingGap = backlogColumn.frame.minX - columnsViewport.frame.minX
                let trailingGap = columnsViewport.frame.maxX - reviewColumn.frame.maxX
                return backlogColumn.frame.minX < backlogColumnFrameWhileChatOpen.minX - 1
                    && leadingGap > 31 + 40
                    && abs(leadingGap - trailingGap) <= 4
            }, timeout: 5),
            "Closing chat should center the board columns in the wider board: backlog=\(backlogColumn.frame), review=\(reviewColumn.frame), board=\(columnsViewport.frame)."
        )
        attachAppWindowScreenshot(named: "Board columns centered below the header after closing chat")
    }
}

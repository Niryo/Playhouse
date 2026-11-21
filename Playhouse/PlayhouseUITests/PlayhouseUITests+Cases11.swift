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
    // case-contract: test_composer_draft_autosaves_during_active_turn | Composer text typed while the agent responds is autosaved as an unsent draft together with its attached image, without ending the turn's submitted prompt or changing its status, and malformed draft images fail validation without changing the draft. A follow-up queued from elsewhere and dispatched after the turn does not replace the draft, which stays saved after the turn ends and is restored to the composer with its image after navigating away and after an app restart. Text steered or queued from the composer leaves the saved draft and does not reappear after the turn, and sending the draft clears it, its images leaving once the turn starts. A submitted prompt whose turn never started returns to the composer with its images, together with the draft typed after it.
    func test_composer_draft_autosaves_during_active_turn() throws {
        let sharedFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-draft-serial-success-wait")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sharedFixture.path), "The draft active-turn fixture should be prepared as an executable by the UI runner.")
        for suffix in ["resolve-ready", "resolve-continue", "serial-first-turn", "serial-second-turn-started", "history", "reject-next-steer"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sharedFixture.path + ".\(suffix)"))
        }
        codexFixtureExecutable = sharedFixture.path
        launchApp(defaultParent: fixture.parent.path)
        let title = "Draft beside an active turn"
        try createTaskFixture(title: title, roots: [fixture.primary.path])
        let taskID = try taskID(named: title)
        openTask(named: title)
        XCTAssertTrue(modelPrompt().waitToExist(timeout: 15), "Conversation history should finish loading before the composer is used.")
        let composer = app.textViews.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15))
        let firstPrompt = "Start the turn the draft is typed beside."
        let steeredText = "Steer this into the running turn."
        let queuedText = "Queue this follow-up for after the turn."
        let typedDraft = "Typed while the agent responds; keep me after the turn."
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        let ready = URL(fileURLWithPath: sharedFixture.path + ".resolve-ready")
        let release = URL(fileURLWithPath: sharedFixture.path + ".resolve-continue")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The fixture should hold the turn active while the draft is typed.")
        defer { try? Data("release\n".utf8).write(to: release) }

        // Steered and queued text leaves the composer and the saved draft at once.
        composer.click()
        composer.typeText(steeredText)
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) ?? nil) == steeredText }, timeout: 10), "Text typed during a turn should autosave.")
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(steeredText).waitToExist(timeout: 10), "Command-Return should steer the running turn.")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "" }, timeout: 10))
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) == nil }, timeout: 10), "A steered draft should leave the saved draft.")
        composer.typeText(queuedText)
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "" }, timeout: 10), "Return should queue the follow-up and clear the composer.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) == nil }, timeout: 10), "A queued draft should leave the saved draft.")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        composer.typeText(typedDraft)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(id: taskID) else { return false }
            return record["savedPrompt"] as? String == typedDraft
                && record["hasUnsentDraft"] as? Bool == true
                && (record["draftImageDataURLs"] as? [String])?.count == 1
        }, timeout: 10), "Text and image typed while the agent responds should autosave together.")
        let running = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(running["status"] as? String, "In Progress", "Autosaving a draft must not change the running task's status.")
        XCTAssertEqual(running["pendingSubmittedPrompt"] as? String, firstPrompt, "Autosaving a draft must not end the turn's submitted prompt.")
        let invalidImage = dataDirectory.appendingPathComponent("invalid-draft.png")
        try Data("not an image".utf8).write(to: invalidImage)
        assertCLIError(try runCLI(["task", "draft", taskID, "--text", "Bad image", "--image", invalidImage.path], expectedStatus: 2), code: "invalid_argument")
        let validImage = dataDirectory.appendingPathComponent("valid-draft.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: validImage)
        let excessImages = Array(repeating: ["--image", validImage.path], count: 9).flatMap { $0 }
        assertCLIError(try runCLI(["task", "draft", taskID, "--text", "Too many images"] + excessImages, expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, typedDraft, "A rejected draft must leave the saved draft unchanged.")
        attachScreenshot(named: "Draft and image typed while the agent responds")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: title)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == typedDraft }, timeout: 10), "Reopening during the turn should restore the draft typed beside it.")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "Reopening during the turn should restore the draft image.")
        // Leaving right after typing, before the autosave delay, must still save the text.
        let fullDraft = typedDraft + " Added just before leaving."
        composer.click()
        composer.typeKey(.downArrow, modifierFlags: .command)
        composer.typeText(" Added just before leaving.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) ?? nil) == fullDraft }, timeout: 10), "Going back mid-turn should save text typed just before leaving.")
        openTask(named: title)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == fullDraft }, timeout: 10), "Reopening should restore text typed just before leaving.")

        // The turn ends and the queued follow-up dispatches while the task is closed.
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        try Data("release\n".utf8).write(to: release)
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(id: taskID) else { return false }
            let queue = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? nil
            return record["status"] as? String != "In Progress" && record["pendingSubmittedPrompt"] == nil && queue?.isEmpty == true
        }, timeout: 30), "The turn and its queued follow-up should finish.")
        let settled = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(settled["savedPrompt"] as? String, fullDraft, "A dispatched follow-up must not replace the unsent draft.")
        XCTAssertEqual((settled["draftImageDataURLs"] as? [String])?.count, 1)
        openTask(named: title)
        XCTAssertTrue(transcriptMessage(queuedText).waitToExist(timeout: 15), "The queued follow-up should have run as its own turn.")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == fullDraft }, timeout: 10), "Reopening after the turn must restore the draft, not an empty or steered one.")
        XCTAssertTrue(element("pending-chat-images").exists, "Reopening after the turn should restore the draft image.")
        attachScreenshot(named: "Draft restored after the turn ends")

        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == fullDraft }, timeout: 15), "The draft typed during the turn should survive an app restart.")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The draft image should survive an app restart.")
        attachScreenshot(named: "Draft restored after restarting the app")

        XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 10))
        element("send-message-button").click()
        XCTAssertTrue(transcriptMessage(fullDraft).waitToExist(timeout: 15), "Sending should deliver the restored draft.")
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(id: taskID) else { return false }
            return record["hasUnsentDraft"] as? Bool == false && (record["draftImageDataURLs"] as? [String])?.isEmpty == true
        }, timeout: 15), "Sending the draft should clear the saved draft.")
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: taskID)?["status"] as? String) ?? nil) != "In Progress" }, timeout: 30))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: title)
        XCTAssertTrue(transcriptMessage(fullDraft).waitToExist(timeout: 15))
        XCTAssertEqual(composer.value as? String, "", "A sent draft must not return to the composer.")
        XCTAssertFalse(element("pending-chat-images").exists, "A sent draft image must not return to the composer.")
        attachScreenshot(named: "Sent draft leaves the composer empty")

        // An image-only send leaves the composer and the saved draft too.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: taskID)?["draftImageDataURLs"] as? [String]) ?? nil)?.count == 1 }, timeout: 10), "An attached image should autosave.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 10))
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard let record = try? self.taskRecord(id: taskID) else { return false }
            return record["hasUnsentDraft"] as? Bool == false && (record["draftImageDataURLs"] as? [String])?.isEmpty == true
                && record["status"] as? String != "In Progress"
        }, timeout: 30), "An image-only send should clear its image from the saved draft.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: title)
        // The reopened transcript pins the latest turn, the image-only send.
        let transcriptImages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-image-"))
        XCTAssertTrue(transcriptImages.firstMatch.waitToExist(timeout: 15), "The image-only send should appear in the transcript.")
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertFalse(element("pending-chat-images").exists, "A sent image-only draft must not return to the composer.")

        let neverStarted = "Draft beside a turn that never started"
        try createTaskFixture(title: neverStarted, roots: [fixture.primary.path])
        let neverStartedID = try self.taskID(named: neverStarted)
        let submitted = "Submitted before Playhouse restarted."
        let laterDraft = "Typed after sending, before the restart."
        _ = try runCLI(["task", "prompt", neverStartedID, "--text", submitted, "--status", "In Progress", "--submitted", "true"])
        _ = try runCLI(["task", "draft", neverStartedID, "--text", laterDraft])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: neverStarted)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == submitted + "\n\n" + laterDraft }, timeout: 15), "A prompt whose turn never started should return to the composer with the draft typed after it.")
        XCTAssertEqual(try taskRecord(id: neverStartedID)?["status"] as? String, "Waiting Response")
        XCTAssertFalse(transcriptMessage(submitted).exists, "A never-started prompt returns as a draft, not as a sent message.")
        XCTAssertFalse(element("pause-response-button").exists, "A recovered never-started prompt leaves no turn running.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 5), "A recovered never-started prompt can be sent again.")
        attachScreenshot(named: "Never-started prompt returns with the later draft")

        let neverStartedImage = "Image prompt whose turn never started"
        try createTaskFixture(title: neverStartedImage, roots: [fixture.primary.path])
        let neverStartedImageID = try self.taskID(named: neverStartedImage)
        _ = try runCLI(["task", "prompt", neverStartedImageID, "--text", submitted, "--image", validImage.path, "--status", "In Progress", "--submitted", "true"])
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTask(named: neverStartedImage)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == submitted }, timeout: 15), "A never-started prompt should return to the composer.")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "A never-started prompt should return with its image.")
        XCTAssertFalse(transcriptMessage(submitted).exists, "A never-started prompt returns as a draft, not as a sent message.")
        XCTAssertFalse(element("pause-response-button").exists, "A recovered never-started prompt leaves no turn running.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 5), "A recovered never-started prompt can be sent again.")
        attachScreenshot(named: "Never-started prompt returns with its image")
    }
    // case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline at the caret without sending and Return submits; multiline drafts persist, expand to the editor limit, remain scrollable and editable across reopening, and submitted prompts persist in history. In the UI the transcript's scroller stays hidden while the pointer is over the composer, shows at a subdued opacity only while the transcript is hovered, and hides again when the pointer leaves. As content is typed in short increments through successive wrapped lines after a line break, the newest insertion remains inside the visible composer viewport while its internal document follows the caret without scrolling backward. Typed straight quotes, apostrophes, and double hyphens stay literal rather than being substituted. Blank drafts cannot be sent or stored. Sending requires a configured repository root, while a task with no selected repository can still be sent as standalone. If a submitted prompt has no Codex thread or active send reservation after restart, the task returns to Waiting Response, clears its pending marker, preserves the draft, and returns it to the composer. Sending to an Untitled auto-branch task derives its branch from the generated title or prompt fallback before preparing the worktree and starting the conversation; if it is concurrently renamed while title generation is pending, the custom title determines the auto branch. A standalone Untitled task starts and persists its provider thread while background title generation is still pending. Stop is enabled as soon as the message is sent, while the turn is still launching and not yet interruptible. Diagnostics correlate title generation with the task and thread while excluding prompt and title text. Queued follow-ups persist with task and thread identity, dispatch after a completed turn, and remain visible for explicit retry after interruption. During an active turn, Return queues a follow-up and queued rows offer Steer. The obsolete footer Queue and Steer buttons are absent.
    func test_conversation_composer_rejects_blank_and_supports_live_turn_controls() throws {
        executionTimeAllowance = 360 // This long case covers several restarts and title-generation flows.
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Blank message", roots: [fixture.primary.path])
        let longDraftTaskID = try taskID(named: "Blank message")
        let longDraft = "# Inspect subagents\n" + String(repeating: "Review child activity and preserve the complete result.\n", count: 160)
        _ = try runCLI(["task", "prompt", longDraftTaskID, "--text", longDraft])
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Blank message")
        let draftEditor = element("message-composer")
        let editorViewport = element("message-composer-scroll-view")
        XCTAssertTrue(draftEditor.waitToExist(timeout: 5))
        XCTAssertEqual(draftEditor.elementType, .textView, "The composer should use a native multiline text area.")
        XCTAssertTrue(waitUntil({ draftEditor.value as? String == longDraft }, timeout: 5),
                      "The saved long draft should return after restarting: \(String(describing: draftEditor.value))")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height >= 205 }, timeout: 5), "Opening a saved long draft must expand to the 12-line viewport immediately, before typing.")
        XCTAssertLessThanOrEqual(editorViewport.frame.height, 216, "A long draft must not expand the editor beyond its 12-line viewport cap.")
        attachScreenshot(named: "Long saved draft expands the native composer")
        let draftTopPosition = draftEditor.frame.minY
        editorViewport.swipeUp()
        XCTAssertTrue(editorViewport.scrollBars.firstMatch.waitToExist(timeout: 5), "Scrolling overflow must expose the composer's own native scrollbar.")
        XCTAssertTrue(waitUntil({ draftEditor.frame.minY < draftTopPosition - 20 }, timeout: 5), "Scrolling down must reveal later draft content.")
        let draftLowerPosition = draftEditor.frame.minY
        editorViewport.swipeDown()
        XCTAssertTrue(waitUntil({ draftEditor.frame.minY > draftLowerPosition + 20 }, timeout: 5), "Scrolling up must reveal earlier draft content.")
        draftEditor.click()
        draftEditor.typeKey(.downArrow, modifierFlags: .command)
        draftEditor.typeText("Edited after reopening.")
        let editedDraft = longDraft + "Edited after reopening."
        XCTAssertTrue(waitUntil({ draftEditor.value as? String == editedDraft }, timeout: 5), "The reopened long draft must respond to editing.")
        let documentTopBeforeLineBreak = draftEditor.frame.minY
        draftEditor.typeKey(.return, modifierFlags: .shift)
        var typedAfterLineBreak = ""
        var previousDocumentTop = documentTopBeforeLineBreak
        // No trailing space: autosave trims the draft, as it does to tell a blank draft apart.
        let wrapText = String(repeating: "First characters stay visible across wrapped lines. ", count: 3).trimmingCharacters(in: .whitespaces)
        let wrapChunks = stride(from: 0, to: wrapText.count, by: 2).map { String(wrapText.dropFirst($0).prefix(2)) }
        for chunk in wrapChunks {
            draftEditor.typeText(chunk)
            typedAfterLineBreak += chunk
            XCTAssertTrue(waitUntil({ (draftEditor.value as? String ?? "").hasSuffix(typedAfterLineBreak) }, timeout: 5), "Each increment after a line break must remain present in the composer.")
            let currentDocumentTop = draftEditor.frame.minY
            XCTAssertLessThanOrEqual(currentDocumentTop, previousDocumentTop + 2, "Typing through successive wrapped lines must not scroll the document back and hide the newest characters.")
            let insertionPointY = draftEditor.frame.maxY - 5
            XCTAssertGreaterThanOrEqual(insertionPointY, editorViewport.frame.minY, "The newest insertion must remain below the visible viewport’s top edge at every wrap checkpoint.")
            XCTAssertLessThanOrEqual(insertionPointY, editorViewport.frame.maxY + 2, "The newest insertion must remain inside the visible viewport at every wrap checkpoint.")
            previousDocumentTop = currentDocumentTop
        }
        XCTAssertLessThan(previousDocumentTop, documentTopBeforeLineBreak - 20, "The composer’s internal document must follow the caret as wrapped content grows.")
        let lineBreakDraft = editedDraft + "\n" + typedAfterLineBreak
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longDraftTaskID)?["savedPrompt"] as? String) == lineBreakDraft }, timeout: 10))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5), "Back must remain responsive after editing a long draft.")
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Blank message")
        XCTAssertTrue(waitUntil({ draftEditor.value as? String == lineBreakDraft }, timeout: 5),
                      "The saved draft should return after restarting: \(String(describing: draftEditor.value))")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height >= 205 }, timeout: 5), "The editor must also expand to its 12-line viewport after restarting with a saved draft.")
        draftEditor.click()
        draftEditor.typeKey("a", modifierFlags: .command)
        draftEditor.typeText("Short")
        let shortenedEditor = waitUntil({ editorViewport.frame.height < 60 }, timeout: 5)
        if !shortenedEditor {
            attachScreenshot(named: "Composer after shortening a saved long draft")
        }
        XCTAssertTrue(shortenedEditor, "Shortening the draft should shrink the editor; viewport=\(editorViewport.frame), document=\(draftEditor.frame), text=\(draftEditor.value ?? "")")
        let shortHeight = editorViewport.frame.height
        draftEditor.typeKey("a", modifierFlags: .command)
        // Pasted rather than typed: typing 960 characters takes most of the case's time budget.
        pasteText(String(repeating: "Wrapped text without a newline. ", count: 30), into: draftEditor)
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight + 20 }, timeout: 5), "Wrapping must grow the editor without explicit newlines.")
        draftEditor.typeKey("a", modifierFlags: .command)
        draftEditor.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longDraftTaskID)?["savedPrompt"] as? String) == nil }, timeout: 10))
        let composer = element("message-composer")
        let sendButton = element("send-message-button")
        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        XCTAssertTrue(modelPicker.waitToExist(timeout: 10), "The composer should show the selected model next to its send controls.")
        let modelTaskID = try taskID(named: "Blank message")
        let modelResult = try runCLI(["conversation", "models", modelTaskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        let modelLabel = modelPicker.value as? String ?? modelPicker.label
        let selectedModelValue = modelLabel.components(separatedBy: ", effort:").first?
            .replacingOccurrences(of: "Model: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? modelLabel
        XCTAssertTrue(availableModels.contains(where: {
            selectedModelValue.caseInsensitiveCompare($0["name"] as? String ?? "") == .orderedSame
                || selectedModelValue.caseInsensitiveCompare($0["id"] as? String ?? "") == .orderedSame
        }), "The selected composer model '\(selectedModelValue)' should match an available Codex model: \(availableModels).")
        XCTAssertFalse(sendButton.isEnabled)
        composer.click()
        // Typed punctuation must reach the draft literally: smart quotes or an em dash would
        // change the prompt the provider receives. This detects substitution only while the
        // VM's "Use smart quotes and dashes" preference is on, as it is on a fresh macOS image.
        let literalPunctuation = "Use \"straight\" quotes -- it's literal"
        composer.typeText(literalPunctuation)
        XCTAssertEqual(composer.value as? String, literalPunctuation, "The composer must not substitute smart quotes or dashes for typed punctuation.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longDraftTaskID)?["savedPrompt"] as? String) == literalPunctuation }, timeout: 10),
                      "The saved draft must keep the typed punctuation literal.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String ?? "").isEmpty }, timeout: 5))
        composer.typeText("First line")
        composer.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight }, timeout: 5), "The composer should reserve the empty caret line immediately after a trailing newline.")
        XCTAssertEqual(composer.value as? String, "First line\n", "The trailing newline should remain in the editor before text is entered on the next line.")
        composer.typeText("Second line")
        XCTAssertEqual(composer.value as? String, "First line\nSecond line", "Shift+Enter should add a line without submitting the composer.")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight }, timeout: 5))
        let twoLineHeight = editorViewport.frame.height
        for index in 3...5 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > twoLineHeight }, timeout: 5))
        let fiveLineHeight = editorViewport.frame.height
        for index in 6...9 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > twoLineHeight }, timeout: 5), "The visible composer should grow as a draft gains lines.")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > fiveLineHeight }, timeout: 5), "The visible composer should expand beyond the previous five-line limit.")
        for index in 10...12 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let twelveLineHeight = editorViewport.frame.height
        for index in 13...15 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let expectedLongDraft = (["First line", "Second line"] + (3...15).map { "Line \($0)" }).joined(separator: "\n")
        XCTAssertLessThanOrEqual(editorViewport.frame.height, twelveLineHeight + 2, "The composer should stop growing at its 12-line limit and scroll the remaining draft.")
        XCTAssertEqual(composer.value as? String, expectedLongDraft, "The composer should retain all lines after reaching its scroll limit.")
        XCTAssertTrue(element("conversation-scroll-view").exists, "The transcript should expose its scroll view for reading the full conversation.")
        XCTAssertTrue(sendButton.isEnabled)
        XCTAssertEqual(((try runCLI(["conversation", "history", taskID(named: "Blank message")])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0, "Adding a line must not send a conversation message.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("BeforeAfter")
        composer.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<6 { composer.typeKey(.rightArrow, modifierFlags: []) }
        composer.typeKey(.return, modifierFlags: .shift)
        XCTAssertEqual(composer.value as? String, "Before\nAfter", "Shift+Return must insert at the caret, not append to the draft.")
        XCTAssertEqual(((try runCLI(["conversation", "history", modelTaskID])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0)
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("   ")
        XCTAssertFalse(sendButton.isEnabled, "Whitespace-only messages must not be sent.")

        let taskID = try taskID(named: "Blank message")
        assertCLIError(
            try runCLI(["task", "prompt", taskID, "--text", "Invalid submitted prompt", "--submitted", "true"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["task", "prompt", taskID, "--text", " ", "--status", "In Progress", "--submitted", "true"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["conversation", "send", taskID, "--message", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        if !isLiveIntegration {
            app.terminate()
            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-success-wait").path
            let titleFixtureExecutable = try XCTUnwrap(codexFixtureExecutable)
            launchApp(defaultParent: fixture.parent.path)
            let titleTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any])
            )
            let titleTaskID = try XCTUnwrap(titleTask["id"] as? String)
            XCTAssertEqual(try repositoryRecord(taskID: titleTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
            XCTAssertEqual(try repositoryRecord(taskID: titleTaskID, repositoryPath: fixture.primary.path)?["isPending"] as? Bool, true)
            openTask(named: "Untitled task")
            let titleComposer = element("message-composer")
            XCTAssertTrue(titleComposer.waitToExist(timeout: 10))
            let titlePrompt = "Transcript entry " + String(repeating: "Readable chat content for scrolling. ", count: 40)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            titleComposer.click()
            pasteText(titlePrompt, into: titleComposer) // Typing 1,500 characters exceeds the case budget.
            titleComposer.typeKey(.return, modifierFlags: [])
            let titleFixtureReady = URL(fileURLWithPath: titleFixtureExecutable + ".resolve-ready")
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: titleFixtureReady.path) }, timeout: 15), "The title fixture should hold the task in its title-pending state.")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["title"] as? String, "Generating title…")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["savedPrompt"] as? String, titlePrompt)
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["pendingSubmittedPrompt"] as? String, titlePrompt)
            let backButton = element("back-to-board-button")
            XCTAssertTrue(waitUntil({ backButton.isEnabled }, timeout: 5), "Back should become available after the submitted prompt and title placeholder are persisted.")
            backButton.click()
            let titleTaskCard = element("task-card-\(titleTaskID.uppercased())")
            XCTAssertTrue(titleTaskCard.waitToExist(timeout: 10))
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["title"] as? String, "Generating title…", "The board should retain the title placeholder while title generation is pending.")
            clickTaskCardTitle(titleTaskCard)
            XCTAssertTrue(waitUntil({
                element("task-view-title").exists || element("task-title-generating").exists
            }, timeout: 10), "The active title-pending task should reopen from the board. UI: \(app.debugDescription)")
            XCTAssertEqual(element("message-composer").value as? String, "", "A submitted prompt must not reappear as a draft after returning during title generation.")
            let submittedPromptMessage = app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "user-message-")).firstMatch
            XCTAssertTrue(submittedPromptMessage.waitToExist(timeout: 5), "The submitted prompt should remain visible as a conversation message after reopening.")
            let promptBubbles = app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "user-message-"))
            XCTAssertTrue(waitUntil({ promptBubbles.count == 1 }, timeout: 5), "The submitted prompt should render as exactly one user bubble after reopening; found \(promptBubbles.count).")
            XCTAssertTrue(element("pause-response-button").exists, "The reopened task should retain its active-send controls while the Codex thread is being prepared.")
            XCTAssertTrue(element("pause-response-button").isEnabled, "Stop must work while the turn is still launching, before Codex has an interruptible turn.")
            XCTAssertFalse(element("send-message-button").exists, "A second message must not be sent while the submitted prompt is still active.")
            try Data("continue\n".utf8).write(to: URL(fileURLWithPath: titleFixtureExecutable + ".resolve-continue"))
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: titleTaskID)?["title"] as? String) ?? nil) == "Generated fixture title"
            }, timeout: 20), "Sending a prompt from an empty task should persist the Codex-generated title.")
            XCTAssertTrue(waitUntil({
                guard let repository = try? self.repositoryRecord(taskID: titleTaskID, repositoryPath: self.fixture.primary.path) else { return false }
                return (repository["branch"] as? String)?.hasPrefix("generated-fixture-title") == true && repository["isPending"] as? Bool == false
            }, timeout: 20), "The auto worktree should use the generated task title.")
            let generatedTitleBranch = try XCTUnwrap(repositoryRecord(taskID: titleTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String)
            try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(generatedTitleBranch)")
            XCTAssertTrue(waitUntil({
                (try? self.diagnosticEvents().contains { $0["taskID"] as? String == titleTaskID && $0["event"] as? String == "task.title_apply.succeeded" }) == true
            }, timeout: 10), "The generated title application should be logged.")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["savedPrompt"] as? String, titlePrompt)
            let titleEvents = try diagnosticEvents().filter { $0["taskID"] as? String == titleTaskID }
            let generationStarted = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_generation.started" })
            let generationSucceeded = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_generation.succeeded" })
            let titleApplied = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_apply.succeeded" })
            XCTAssertEqual(generationStarted["threadID"] as? String, generationSucceeded["threadID"] as? String)
            XCTAssertTrue((generationStarted["threadID"] as? String)?.isEmpty == false)
            XCTAssertTrue((generationSucceeded["threadID"] as? String)?.isEmpty == false)
            XCTAssertEqual(titleApplied["titleSource"] as? String, "codex")
            let serializedTitleEvents = String(data: try JSONSerialization.data(withJSONObject: titleEvents), encoding: .utf8) ?? ""
            XCTAssertFalse(serializedTitleEvents.contains(titlePrompt), "Title diagnostics must not include conversation text.")
            XCTAssertFalse(serializedTitleEvents.contains("Generated fixture title"), "Title diagnostics must not include generated title text.")
            let transcriptScrollView = element("conversation-scroll-view")
            let longPromptMessage = app.textViews.matching(
                NSPredicate(format: "value BEGINSWITH %@", "Transcript entry Readable chat content")
            ).firstMatch
            XCTAssertTrue(longPromptMessage.waitToExist(timeout: 5), "The full long prompt should remain present in conversation history.")
            XCTAssertTrue(transcriptScrollView.scrollBars.firstMatch.waitToExist(timeout: 5), "An overflowing transcript should expose a visible scrollbar.")
            let latestPosition = longPromptMessage.frame.minY
            transcriptScrollView.swipeDown()
            XCTAssertTrue(waitUntil({ longPromptMessage.frame.minY > latestPosition + 20 }, timeout: 5), "Scrolling up should reveal earlier content in the long message.")
            let earlierPosition = longPromptMessage.frame.minY
            transcriptScrollView.swipeUp()
            XCTAssertTrue(waitUntil({ longPromptMessage.frame.minY < earlierPosition - 20 }, timeout: 5), "Scrolling down should return to later content in the long message.")
            try assertScrollerRevealsOnlyOnHover(transcriptScrollView, elsewhere: element("message-composer"), named: "transcript")
            _ = try runCLI(["task", "rename", titleTaskID, "--title", "Generated title success"])
            element("back-to-board-button").click()

            app.terminate()
            let activeTitleFixtureExecutable = WorkspaceFixture.root
                .appendingPathComponent("codex-fixture-root-title-success-wait").path
            try? FileManager.default.removeItem(atPath: activeTitleFixtureExecutable)
            try copyFixtureFile(
                at: URL(fileURLWithPath: titleFixtureExecutable),
                to: URL(fileURLWithPath: activeTitleFixtureExecutable)
            )
            codexFixtureExecutable = activeTitleFixtureExecutable
            launchApp(defaultParent: fixture.parent.path)
            let standaloneTitleTask = try XCTUnwrap(
                (try runCLI([
                    "task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--root", fixture.primary.path
                ])["result"] as? [String: Any])
            )
            let standaloneTitleTaskID = try XCTUnwrap(standaloneTitleTask["id"] as? String)
            openTask(named: "Untitled task")
            let standaloneComposer = element("message-composer")
            XCTAssertTrue(standaloneComposer.waitToExist(timeout: 10))
            standaloneComposer.click()
            standaloneComposer.typeText("Persist the provider thread before this background title finishes.")
            standaloneComposer.typeKey(.return, modifierFlags: [])
            let standaloneTitleReady = URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-ready")
            XCTAssertTrue(waitUntil({
                FileManager.default.fileExists(atPath: standaloneTitleReady.path)
            }, timeout: 15), "The standalone title fixture should hold background title generation.")
            XCTAssertEqual(try taskRecord(id: standaloneTitleTaskID)?["title"] as? String, "Generating title…")
            XCTAssertNotNil(
                try taskRecord(id: standaloneTitleTaskID)?["codexThreadID"] as? String,
                "A standalone task should persist its provider thread before background title generation finishes."
            )
            try Data("continue standalone title\n".utf8).write(
                to: URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-continue")
            )
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: standaloneTitleTaskID)?["title"] as? String) ?? nil) == "Generated fixture title"
            }, timeout: 20))
            element("back-to-board-button").click()

            let concurrentTitleTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path])["result"] as? [String: Any])
            )
            let concurrentTitleTaskID = try XCTUnwrap(concurrentTitleTask["id"] as? String)
            let concurrentTitle = "Concurrent custom branch title"
            let concurrentPrompt = "Use the concurrently selected task title for this worktree."
            let concurrentTitleReady = URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-ready")
            let concurrentTitleRelease = URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-continue")
            try? FileManager.default.removeItem(at: concurrentTitleReady)
            try? FileManager.default.removeItem(at: concurrentTitleRelease)
            openTask(named: "Untitled task")
            let concurrentComposer = element("message-composer")
            XCTAssertTrue(concurrentComposer.waitToExist(timeout: 10))
            concurrentComposer.click()
            concurrentComposer.typeText(concurrentPrompt)
            concurrentComposer.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitUntil({
                FileManager.default.fileExists(atPath: concurrentTitleReady.path)
            }, timeout: 15), "Title generation should remain pending during the concurrent rename.")
            let renameResult = try runCLI([
                "task", "rename", concurrentTitleTaskID, "--title", concurrentTitle
            ])
            XCTAssertEqual((renameResult["result"] as? [String: Any])?["title"] as? String, concurrentTitle)
            try Data("continue concurrent rename\n".utf8).write(to: concurrentTitleRelease)
            XCTAssertTrue(waitUntil({
                guard let repository = try? self.repositoryRecord(taskID: concurrentTitleTaskID, repositoryPath: self.fixture.secondary.path) else { return false }
                return repository["branch"] as? String == "concurrent-custom-branch-title"
                    && repository["isPending"] as? Bool == false
            }, timeout: 20), "A concurrent custom title should determine the prepared auto-worktree branch.")
            XCTAssertEqual(try taskRecord(id: concurrentTitleTaskID)?["title"] as? String, concurrentTitle)
            element("back-to-board-button").click()

            // The send must end before reaching Codex: its branch-from is deleted while title generation is held.
            try runGit(fixture.primary, "branch", "recovery-base", "HEAD")
            let recoveryTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--branch-from", "\(fixture.primary.path)=recovery-base"])["result"] as? [String: Any])
            )
            let recoveryTaskID = try XCTUnwrap(recoveryTask["id"] as? String)
            openTask(named: "Untitled task")
            let recoveryPrompt = "Recover this prompt after Playhouse closes before Codex starts."
            // The app relaunched with the active title fixture, which holds this send's title generation.
            let recoveryFixtureReady = URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-ready")
            try? FileManager.default.removeItem(at: recoveryFixtureReady)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-continue"))
            element("message-composer").click()
            element("message-composer").typeText(recoveryPrompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: recoveryFixtureReady.path) }, timeout: 15))
            XCTAssertEqual(try taskRecord(id: recoveryTaskID)?["codexThreadID"] as? String, nil)
            XCTAssertEqual(try taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"] as? String, recoveryPrompt)
            app.terminate()
            try runGit(fixture.primary, "branch", "-D", "recovery-base")
            try Data("continue recovery\n".utf8).write(to: URL(fileURLWithPath: activeTitleFixtureExecutable + ".resolve-continue"))
            launchApp(defaultParent: fixture.parent.path)
            let recoveryTaskCard = element("task-card-\(recoveryTaskID.uppercased())")
            XCTAssertTrue(recoveryTaskCard.waitToExist(timeout: 10))
            clickTaskCardTitle(recoveryTaskCard)
            XCTAssertTrue(waitUntil({
                element("task-view-title").exists || element("task-title-generating").exists
            }, timeout: 10), "The recovered task should reopen while its title is still being generated.")
            // The daemon restores the send's earlier status when the send ends without reaching Codex.
            XCTAssertTrue(waitUntil({
                ["Waiting Response", "Backlog"].contains(((try? self.taskRecord(id: recoveryTaskID)?["status"] as? String) ?? nil) ?? "")
                    && ((try? self.taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"]) is NSNull || (try? self.taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"]) == nil)
            }, timeout: 10), "Reopening a task whose send never reached Codex should clear the pending marker and leave the task ready to continue.")
            XCTAssertTrue(waitUntil({
                (self.element("message-composer").value as? String) == recoveryPrompt
            }, timeout: 10), "A stale submitted prompt should return to the composer for retry. composer=\(String(describing: element("message-composer").value)) record=\(draftStateSummary(recoveryTaskID))")
            XCTAssertFalse(transcriptMessage(recoveryPrompt).exists, "A turn that never reached Codex should not be shown as a sent message.")

            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-failure").path
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            let failureTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any])
            )
            let failureTaskID = try XCTUnwrap(failureTask["id"] as? String)
            XCTAssertEqual(try repositoryRecord(taskID: failureTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
            openTask(named: "Untitled task")
            let failureComposer = element("message-composer")
            XCTAssertTrue(failureComposer.waitToExist(timeout: 10))
            let failurePrompt = "Explain how repository setup works for new contributors"
            let rpcFailureCountBeforeSend = try diagnosticEvents().filter {
                $0["event"] as? String == "codex.rpc.response.failed" && $0["errorCode"] as? String == "-32042"
            }.count
            failureComposer.click()
            failureComposer.typeText(failurePrompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: failureTaskID)?["title"] as? String) ?? nil) == failurePrompt
            }, timeout: 20), "When title generation fails, the submitted prompt should become the persisted fallback title.")
            XCTAssertTrue(waitUntil({
                guard let repository = try? self.repositoryRecord(taskID: failureTaskID, repositoryPath: self.fixture.primary.path) else { return false }
                return repository["branch"] as? String == "explain-how-repository-setup-works-for-new-contributors" && repository["isPending"] as? Bool == false
            }, timeout: 20), "A failed title generation should derive the new auto branch from its prompt fallback.")
            try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/explain-how-repository-setup-works-for-new-contributors")
            XCTAssertTrue(waitUntil({
                (try? self.diagnosticEvents().contains { $0["taskID"] as? String == failureTaskID && $0["event"] as? String == "task.title_apply.succeeded" }) == true
            }, timeout: 10), "The prompt fallback application should be logged.")
            XCTAssertEqual(try taskRecord(id: failureTaskID)?["savedPrompt"] as? String, failurePrompt)
            let failureTitleEvents = try diagnosticEvents().filter { $0["taskID"] as? String == failureTaskID }
            let titleGenerationFailure = try XCTUnwrap(failureTitleEvents.first { $0["event"] as? String == "task.title_generation.failed" })
            let fallbackApplied = try XCTUnwrap(failureTitleEvents.first { $0["event"] as? String == "task.title_apply.succeeded" })
            XCTAssertEqual(titleGenerationFailure["phase"] as? String, "title-turn")
            XCTAssertTrue((titleGenerationFailure["threadID"] as? String)?.isEmpty == false)
            XCTAssertTrue((titleGenerationFailure["errorDescription"] as? String)?.isEmpty == false)
            XCTAssertTrue((titleGenerationFailure["errorDescription"] as? String)?.contains("Fixture rejected task-title generation.") == true)
            let rpcFailures = try diagnosticEvents().filter {
                $0["event"] as? String == "codex.rpc.response.failed" && $0["errorCode"] as? String == "-32042"
            }
            XCTAssertEqual(rpcFailures.count, rpcFailureCountBeforeSend + 1, "The title turn server error should produce one RPC failure diagnostic.")
            let rpcFailure = try XCTUnwrap(rpcFailures.last)
            XCTAssertEqual(rpcFailure["errorDescription"] as? String, "Codex returned an RPC error.")
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: rpcFailure), encoding: .utf8)?.contains(failurePrompt) == true, "RPC diagnostics must not store server errors that echo conversation text.")
            XCTAssertEqual(fallbackApplied["titleSource"] as? String, "prompt-fallback")
            let serializedFailureTitleEvents = String(data: try JSONSerialization.data(withJSONObject: failureTitleEvents), encoding: .utf8) ?? ""
            XCTAssertFalse(serializedFailureTitleEvents.contains(failurePrompt), "Title diagnostics must not include conversation text.")
            let queuedText = "Follow up after the next turn."
            _ = try runCLI(["conversation", "queue", failureTaskID, "--message", queuedText])
            let reloadedQueue = try runCLI(["conversation", "queue-list", failureTaskID])["result"] as? [[String: Any]]
            XCTAssertEqual(reloadedQueue?.first?["text"] as? String, queuedText, "The queue should persist through a fresh CLI/XPC read.")
            let queuedMessageID = try XCTUnwrap(reloadedQueue?.first?["id"] as? String)
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: failurePrompt)
            let queuedMessageRow = element("queued-message-text-\(queuedMessageID)")
            XCTAssertTrue(queuedMessageRow.waitToExist(timeout: 10), "The saved queued follow-up should appear after reopening the conversation.")
            XCTAssertEqual(queuedMessageRow.value as? String, queuedText)
            app.terminate()
            // A plain fixture, never the installed Codex CLI.
            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui").path
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: "Blank message")
        }
        if isLiveIntegration {
            try useLiveProvider(taskID: taskID)
            let livePrompt = "In playhouse-primary.txt, append exactly the line `Playhouse UI pause marker 6A20F1`. Then run a shell command that executes `sleep 90; printf PAUSE_TEST_FINISHED`. Do not modify any other files. Reply with a short summary after the command finishes."
            let savedPrompt = try runCLI(["task", "prompt", taskID, "--text", livePrompt])["result"] as? [String: Any]
            XCTAssertEqual(savedPrompt?["savedPrompt"] as? String, livePrompt)
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeText(livePrompt)
            XCTAssertTrue(sendButton.isEnabled, "A nonblank draft in a live Codex session should enable Send.")
            sendButton.click()

            let pauseButton = element("pause-response-button")
            XCTAssertTrue(pauseButton.waitToExist(timeout: 60), "A live turn should replace Send with Pause.")
            XCTAssertTrue(pauseButton.isEnabled, "Pause should be enabled after Codex reports an active turn.")
            XCTAssertFalse(element("steer-current-turn-button").exists, "The old footer Steer button should be absent during a turn.")
            XCTAssertFalse(element("queue-message-after-turn-button").exists, "The old footer Queue button should be absent during a turn.")
            XCTAssertTrue(app.staticTexts["Ask for follow-up changes"].exists, "The active composer should identify follow-up changes.")
            let queuedText = "Afterward, report that the queued message was dispatched."
            composer.click()
            composer.typeText(queuedText)
            composer.typeKey(.return, modifierFlags: [])
            let queuedDuringLiveTurn = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
            XCTAssertEqual(queuedDuringLiveTurn?.first?["text"] as? String, queuedText, "Return should queue the active-turn follow-up.")
            XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitToExist(timeout: 10), "Queueing should persist and visibly distinguish a follow-up from steering.")

            element("back-to-board-button").click()
            openTask(named: "Blank message")
            XCTAssertTrue(element("pause-response-button").waitToExist(timeout: 30), "Reopening the task should retain the active-turn controls.")
            XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitToExist(timeout: 10), "The queued follow-up should survive closing and reopening the conversation.")
            XCTAssertEqual(composer.value as? String, "", "A prompt already sent to Codex must not reappear as a composer draft.")
            let reopenedActivity = element("codex-activity-disclosure")
            let visibleThinking = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Thinking", "Running")
            let thinkingExpectation = XCTNSPredicateExpectation(predicate: visibleThinking, object: reopenedActivity)
            XCTAssertEqual(XCTWaiter.wait(for: [thinkingExpectation], timeout: 30), .completed, "An active turn should remain visibly active after leaving and reopening the task.")
            XCTAssertTrue(waitUntil({ reopenedActivity.value as? String == "Expanded, down chevron" }, timeout: 15),
                          "Reopening a task mid-turn should land on the same open section instead of hiding the work behind Working for.")

            let activityDisclosure = element("codex-activity-disclosure")
            guard activityDisclosure.waitToExist(timeout: 60) else {
                attachScreenshot(named: "Live turn did not surface Codex activity")
                let liveHistory = try? runCLI(["conversation", "history", taskID])
                let liveRows = ((liveHistory?["result"] as? [String: Any])?["activities"] as? [[String: Any]] ?? [])
                    .map { "\($0["status"] ?? "unknown"): \($0["title"] ?? "untitled")" }
                let task = try taskRecord(named: "Blank message")
                let roots = task?["workspaceRoots"] as? [String] ?? []
                let markerPath = roots.first.map { URL(fileURLWithPath: $0).appendingPathComponent("playhouse-primary.txt") }
                let markerPresent = markerPath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("Playhouse UI pause marker 6A20F1") ?? false
                XCTFail("The active tool did not appear in the UI. Persisted activity rows: \(liveRows); fixture edit applied: \(markerPresent).")
                return
            }
            let runningTitle = NSPredicate(format: "label CONTAINS %@", "Running 1 task")
            let runningActivityExpectation = XCTNSPredicateExpectation(predicate: runningTitle, object: activityDisclosure)
            XCTAssertEqual(
                XCTWaiter.wait(for: [runningActivityExpectation], timeout: 60),
                .completed,
                "The activity title should report the current running-task count."
            )
            let activityRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "codex-activity-row-", "sleep 90; printf PAUSE_TEST_FINISHED"))
                .firstMatch
            XCTAssertTrue(activityRow.waitToExist(timeout: 30), "A live turn should show its running command row without the reader opening anything.")
            attachScreenshot(named: "Running chat composer and open Codex activity")
            // The open section is a default, not a lock. The running row keeps the
            // live slot outside the section, so the chevron is what folds here.
            activityDisclosure.click()
            XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Collapsed, right chevron" }, timeout: 10),
                          "A reader's mid-turn collapse should be honored.")
            activityDisclosure.click()
            XCTAssertTrue(waitUntil({ activityDisclosure.value as? String == "Expanded, down chevron" }, timeout: 10),
                          "Reopening the section mid-turn should restore the open chevron.")
            XCTAssertTrue(activityRow.waitToExist(timeout: 30), "The running command row should remain available.")

            pauseButton.click()
            let continueButton = element("continue-response-button")
            XCTAssertTrue(continueButton.waitToExist(timeout: 30), "An interrupted response should offer Continue.")
            attachScreenshot(named: "Paused response with Continue control")
            continueButton.click()
            XCTAssertTrue(sendButton.waitToExist(timeout: 120), "The continued response should return the composer to Send.")
            let pauseEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pauseButton)
            let continueEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: continueButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [pauseEnded, continueEnded], timeout: 30),
                .completed,
                "A completed response should no longer show Pause or Continue."
            )
            let completedAssistantMessage = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value != ''", "assistant-message-"))
                .firstMatch
            XCTAssertTrue(completedAssistantMessage.waitToExist(timeout: 30), "Continue should finish the response and show its assistant message in the conversation.")
            attachScreenshot(named: "Continued response completed in the conversation")
        }
        attachScreenshot(named: "Blank composer leaves send disabled")
    }
    // case-contract: test_codex_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Codex reasoning immediately moves the task to Waiting Response and sends Codex's turn-scoped turn/interrupt request. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles. The turn's activity section renders open for as long as the daemon reports the turn active, and folds once the stop settles with no final answer. The observed Codex message time survives interruption and reload. In the window Continue replaces Stop at once, before the provider acknowledges the interrupt. The fixture acknowledges Stop while withholding the terminal event. Playhouse settles the turn and allows a provider switch.
    func test_codex_stop_interrupts_thinking_turn_and_waits_for_response() throws {
        try exerciseStopDuringThinking(provider: "codex", title: "Codex stop while thinking")
    }
    // case-contract: test_claude_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Claude reasoning immediately moves the task to Waiting Response and sends Claude's session-scoped control interrupt. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles. The turn's activity section renders open for as long as the daemon reports the turn active, and folds once the stop settles with no final answer. In the window Continue replaces Stop at once, before the provider acknowledges the interrupt. The fixture acknowledges Stop while withholding the terminal event. Playhouse settles the turn and allows a provider switch.
    func test_claude_stop_interrupts_thinking_turn_and_waits_for_response() throws {
        try exerciseStopDuringThinking(provider: "claude", title: "Claude stop while thinking")
    }
    // case-contract: test_claude_confirms_stop_of_background_process | Stopping a Claude turn with a running background process asks for confirmation. Declining keeps the turn and its process alive. Confirming stops the turn and kills its child even when the child is in a separate process group. A provider switch can then be saved, and a fresh task read keeps the selected provider and Waiting Response status.
    func test_claude_confirms_stop_of_background_process() throws {
        let title = "Claude background stop"
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.",
            "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let executable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui").path
        let childMarker = URL(fileURLWithPath: executable + ".stop-child")
        try? FileManager.default.removeItem(at: childMarker)
        claudeFixtureExecutable = executable
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped with a background process.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: childMarker.path) }, timeout: 15))
        let pid = try XCTUnwrap(Int32(String(contentsOf: childMarker, encoding: .utf8)))
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.isEnabled }, timeout: 5))
        stop.click()
        let confirmation = app.sheets.containing(.staticText, identifier: "Stop background work?").firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 5))
        attachAppWindowScreenshot(named: "Claude background work confirmation")
        attachScreenshot(named: "Claude confirmation in context")
        attachElementScreenshot(confirmation, named: "Claude confirmation choices")
        confirmation.buttons["Keep Running"].click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        XCTAssertEqual(kill(pid, 0), 0)
        stop.click()
        XCTAssertTrue(confirmation.waitToExist(timeout: 5))
        confirmation.buttons["Stop All"].click()
        try switchProviderAfterStop(taskID: taskID, provider: "codex")
        XCTAssertTrue(waitUntil({ kill(pid, 0) != 0 }, timeout: 5))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
    }
    // case-contract: test_codex_confirms_stop_of_active_background_terminal | A running Codex turn with a background terminal requires confirmation before stopping. Declining keeps the terminal running. Confirming terminates that thread's terminal, settles the turn even if the interrupt is unanswered, and allows a switch to Claude while the shared Codex server stays alive.
    func test_codex_confirms_stop_of_active_background_terminal() throws {
        let title = "Codex active background stop"
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.",
            "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold-interrupt").path
        for suffix in ["interrupt-ready", "interrupt-received", "background-state", "history"] {
            try? FileManager.default.removeItem(atPath: "\(executable).\(suffix)")
        }
        let backgroundState = URL(fileURLWithPath: executable + ".background-state")
        func terminalState() -> [String: Any] {
            guard let data = try? Data(contentsOf: backgroundState) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        codexFixtureExecutable = executable
        claudeFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped with a Codex background command.")
        element("send-message-button").click()
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({
            stop.isEnabled && (terminalState()["running"] as? [String: Any])?.count == 1
        }, timeout: 15))
        let server = try XCTUnwrap(agentManifests().first {
            $0.kind == "codex" && agentIsAlive($0.manifest["process"] as? [String: Any])
        }?.manifest["process"] as? [String: Any])
        stop.click()
        let confirmation = app.sheets.containing(.staticText, identifier: "Stop background work?").firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 5))
        confirmation.buttons["Keep Running"].click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        XCTAssertEqual((terminalState()["running"] as? [String: Any])?.count, 1)
        stop.click()
        XCTAssertTrue(confirmation.waitToExist(timeout: 5))
        attachScreenshot(named: "Stop confirmation with a live Codex turn")
        attachElementScreenshot(confirmation, named: "Codex active turn confirmation choices")
        confirmation.buttons["Stop All"].click()
        try switchProviderAfterStop(taskID: taskID, provider: "claude")
        XCTAssertEqual(terminalState()["terminated"] as? [String], ["49264"])
        XCTAssertTrue(agentIsAlive(server), "The same shared Codex server stays alive.")
    }
    // case-contract: test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle | The bridge daemon starts on the first request, exactly once even when callers race to start it, serves later requests from the same process, and stays alive while any connection (such as a window's runtime or CPU usage watcher) is open. A watcher receives the daemon's runtime snapshots as a turn starts and stops, and the daemon exits by itself once the last connection closes and no request is running; the next request starts a fresh daemon on demand without any manual step.
    func test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle() throws {
        // Its own daemon, separate from the one the UI runner keeps alive for every
        // case. The app starts it: the sandboxed test runner can only connect.
        let graceEnvironment = [
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).lifecycle-\(UUID().uuidString.prefix(8))",
            "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS": "3",
        ]
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold-interrupt").path
        codexFixtureExecutable = executable
        let ready = URL(fileURLWithPath: executable + ".interrupt-ready")
        let received = URL(fileURLWithPath: executable + ".interrupt-received")
        let release = URL(fileURLWithPath: executable + ".interrupt-release")
        for marker in [ready, received, release] { try? FileManager.default.removeItem(at: marker) }
        func daemonPID() throws -> Int {
            let status = try XCTUnwrap(try runCLI(["status"], extraEnvironment: graceEnvironment)["result"] as? [String: Any])
            return try XCTUnwrap(status["processID"] as? Int)
        }
        func isRunning(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 }

        // The open window is a watcher: it starts the daemon and keeps it alive.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: graceEnvironment)
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Daemon watcher", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "codex",
        ], extraEnvironment: graceEnvironment)["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let firstPID = try daemonPID()
        XCTAssertTrue(isRunning(firstPID), "The window's first request should have started a daemon.")
        // The window sends several requests at once on launch; racing to start the daemon, they start exactly one.
        XCTAssertEqual(daemonLogProcessIDs(service: graceEnvironment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]!), [firstPID],
                       "Only one daemon should have been started.")
        XCTAssertEqual(try daemonPID(), firstPID, "Later requests should reuse the running daemon.")
        RunLoop.current.run(until: Date().addingTimeInterval(4.5))
        XCTAssertTrue(isRunning(firstPID), "An open window keeps the daemon alive past its idle grace.")
        XCTAssertEqual(try daemonPID(), firstPID)
        let idle = try XCTUnwrap(try runCLI(["conversation", "runtime"], extraEnvironment: graceEnvironment)["result"] as? [String: Any])
        XCTAssertEqual(idle["activeThreadIDs"] as? [String], [], "A daemon with no turns reports nothing active.")

        // The window sees the daemon's turn start and stop.
        openTask(named: "Daemon watcher")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("Hold until stopped.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The held turn should be thinking.")
        let threadID = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        let running = try XCTUnwrap(try runCLI(["conversation", "runtime"], extraEnvironment: graceEnvironment)["result"] as? [String: Any])
        XCTAssertTrue((running["activeThreadIDs"] as? [String] ?? []).contains(threadID))
        XCTAssertTrue((running["interruptibleThreadIDs"] as? [String] ?? []).contains(threadID))
        let stop = element("pause-response-button")
        XCTAssertTrue(waitUntil({ stop.exists && stop.isEnabled }, timeout: 15), "The window should show Stop for the daemon's running turn.")
        _ = try runCLI(["conversation", "stop", taskID], extraEnvironment: graceEnvironment)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: received.path) }, timeout: 10))
        try Data("acknowledge interrupt\n".utf8).write(to: release)
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 15), "The window should show the turn as paused once the daemon settles it.")
        let stopped = try XCTUnwrap(try runCLI(["conversation", "runtime"], extraEnvironment: graceEnvironment)["result"] as? [String: Any])
        XCTAssertFalse((stopped["activeThreadIDs"] as? [String] ?? []).contains(threadID))
        XCTAssertTrue((stopped["interruptedThreadIDs"] as? [String] ?? []).contains(threadID))

        // Closing the last connection lets the daemon go; the next request starts a new one.
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must quit before the daemon can go idle.")
        XCTAssertTrue(waitUntil({ !isRunning(firstPID) }, timeout: 20), "The daemon should exit by itself once its last connection closes and no request is running.")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: graceEnvironment)
        let secondPID = try daemonPID()
        XCTAssertNotEqual(secondPID, firstPID, "The next request should start a fresh daemon on demand.")
        XCTAssertTrue(isRunning(secondPID))
    }
}

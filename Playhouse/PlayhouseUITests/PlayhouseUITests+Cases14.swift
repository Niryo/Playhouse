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
    // case-contract: test_conversation_adds_ordered_text_annotations | Selecting text in assistant and user messages, including wrapped multiline selections, shows a Side chat hint above the selected lines in place of the Add comment hint; clicking it opens the side chat bubble at the selected lines, and the bubble's Comment button adds what is typed in its composer as a comment on the selection and closes it. Added ranges render orange and persist after reopening. The composer shows the pending comment count. Structurally recognized comment context is hidden while similar ordinary text remains visible; comments are sent in insertion order with source ranges alongside ordinary composer text. Multiple comments can be added before one send, comment-only sends are enabled, and closing the bubble with Escape leaves none to submit. Pending comments take precedence over Goal-entry mode: submission sends them to the conversation, exits Goal-entry mode, and does not store the comment payload as a Goal objective. The agent is instructed to start each comment response line with the provider-neutral indexed protocol marker; the transcript renders that marker as a numbered prefix (1., 2.) whose hover opens a medium-sized hint with highlighted text and the user's comment, truncating long values while keeping them identifiable. The serialized payload and ordered response survive CLI/XPC history reload. Legacy Codex markers, response-annotations payloads, and annotation fields still restore their reply details. Consecutive paragraphs, headings, and list items of a reply form one selectable text: the comment reply's lines share one text with a paragraph each, and selecting across them adds one comment that highlights every covered paragraph, records the block it ends in alongside its start block and offsets (a comment inside one block keeps the original source fields), and is restored after reopening the conversation; the cross-block source survives CLI/XPC history reload. User messages render in a neutral gray, input-style bubble with a thin light border and light text rather than the blue accent fill.
    func test_conversation_adds_ordered_text_annotations() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-goal-success").path
        let fixtureStateDirectory = dataDirectory.appendingPathComponent("comment-goal-fixture-state", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureStateDirectory, withIntermediateDirectories: true)
        codexFixtureStateDirectory = fixtureStateDirectory
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Comment source", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Comment source")
        let sourceText = "Long response fixture input. A user message with selectable words. Literal # Response comments: stays visible. "
            + String(repeating: "Additional context spans across multiple visual lines. ", count: 5)
        _ = try runCLI([
            "conversation", "send", taskID, "--message", sourceText,
        ])
        let legacyComment = "A detail from older saved history"
        let legacyPayload = try JSONSerialization.data(withJSONObject: [[
            "text": "legacy highlighted words", "annotation": legacyComment,
            "source": ["messageId": "legacy-source", "blockID": 0, "startOffset": 0, "endOffset": 24],
        ]])
        let legacyPayloadText = try XCTUnwrap(String(data: legacyPayload, encoding: .utf8))
        let legacyPrompt = "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order.\n"
            + "<response-annotations>\(legacyPayloadText)</response-annotations>"
        _ = try runCLI([
            "conversation", "send", taskID, "--message", legacyPrompt,
        ])
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let messages = try XCTUnwrap(history?["messages"] as? [[String: Any]])
        let sourceMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
        let sourceID = try XCTUnwrap(sourceMessage["id"] as? String)
        let assistantMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        let assistantID = try XCTUnwrap(assistantMessage["id"] as? String)
        XCTAssertFalse(try XCTUnwrap(assistantMessage["text"] as? String).isEmpty)
        // Double-clicking the first word selects it in one step, as the side chat bubble opens
        // once a selection settles.
        let userSelection = "Long"
        var assistantSelection = ""
        openTask(named: "Comment source")
        let seededHistory = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let seededMessages = try XCTUnwrap(seededHistory?["messages"] as? [[String: Any]])
        let seededLegacyMessage = try XCTUnwrap(seededMessages.first {
            ($0["role"] as? String) == "assistant" && (($0["text"] as? String)?.contains("legacy highlighted words") ?? false)
        })
        let seededLegacyID = try XCTUnwrap(seededLegacyMessage["id"] as? String)
        let seededLegacyResponse = element("assistant-message-\(seededLegacyID)")
        let seededLegacyLink = seededLegacyResponse.descendants(matching: .staticText).matching(
            NSPredicate(format: "value CONTAINS %@", "Comment 1")
        ).firstMatch
        XCTAssertTrue(seededLegacyLink.waitToExist(timeout: 5))
        // The opened transcript is still pinning its latest turn; a screenshot of a moving row misses the glyphs.
        XCTAssertTrue(waitForStableFrame(seededLegacyLink), "The seeded comment link should stop moving before its glyphs are measured.")
        // Locate the rendered marker glyphs directly; accessibility text-view
        // frames include font-dependent padding and do not match glyph positions.
        let seededCommentHint = element("response-comment-hover-card")
        let markerImage = try XCTUnwrap(seededLegacyLink.screenshot().image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ))
        let markerBitmap = NSBitmapImageRep(cgImage: markerImage)
        var blueMinX = markerBitmap.pixelsWide
        var blueMaxX = -1
        var blueMinY = markerBitmap.pixelsHigh
        var blueMaxY = -1
        for x in 0..<markerBitmap.pixelsWide {
            for y in 0..<markerBitmap.pixelsHigh {
                guard let color = markerBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > 0.6 && color.blueComponent > color.redComponent + 0.25
                    && color.blueComponent > color.greenComponent + 0.08 {
                    blueMinX = min(blueMinX, x)
                    blueMaxX = max(blueMaxX, x)
                    blueMinY = min(blueMinY, y)
                    blueMaxY = max(blueMaxY, y)
                }
            }
        }
        XCTAssertGreaterThan(blueMaxY - blueMinY, 3, "The screenshot should locate the rendered blue comment glyphs.")
        let markerPixelsPerPointY = CGFloat(markerBitmap.pixelsHigh) / seededLegacyLink.frame.height
        let markerPixelsPerPointX = CGFloat(markerBitmap.pixelsWide) / seededLegacyLink.frame.width
        let visibleMarkerMidX = seededLegacyLink.frame.minX + CGFloat(blueMinX + blueMaxX) / 2 / markerPixelsPerPointX
        let visibleMarkerTopY = seededLegacyLink.frame.minY + CGFloat(blueMinY) / markerPixelsPerPointY
        let visibleMarkerBottomY = seededLegacyLink.frame.minY + CGFloat(blueMaxY + 1) / markerPixelsPerPointY
        let seededMarkerPointX = min(0.99, max(0.01, (visibleMarkerMidX - seededLegacyLink.frame.minX) / seededLegacyLink.frame.width))
        let seededMarkerPointY = min(0.99, max(0.01, ((visibleMarkerTopY + visibleMarkerBottomY) / 2 - seededLegacyLink.frame.minY) / seededLegacyLink.frame.height))
        let seededMarkerCenter = seededLegacyLink.coordinate(
            withNormalizedOffset: CGVector(dx: seededMarkerPointX, dy: seededMarkerPointY)
        )
        let markerScreenPoint = seededMarkerCenter.screenPoint
        let offCommentCoordinate = seededLegacyLink.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let offCommentPoint = offCommentCoordinate.screenPoint
        func pointerIsNear(_ point: CGPoint) -> Bool {
            guard let currentPoint = CGEvent(source: nil)?.location else { return false }
            return hypot(currentPoint.x - point.x, currentPoint.y - point.y) <= 4
        }
        func waitForPointer(at point: CGPoint, timeout: TimeInterval) -> Date? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pointerIsNear(point) { return Date() }
                Thread.sleep(forTimeInterval: 0.002)
            }
            return nil
        }
        let targetBundleIdentifier = try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier)
        let targetProcessID = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier).first?.processIdentifier
        )
        func visibleAppWindowIDs() -> Set<Int> {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            return Set(windows.compactMap { window in
                guard (window[kCGWindowOwnerPID as String] as? Int) == Int(targetProcessID) else { return nil }
                return window[kCGWindowNumber as String] as? Int
            })
        }
        offCommentCoordinate.hover()
        XCTAssertTrue(pointerIsNear(offCommentPoint), "The timing probe must start with the pointer outside the link.")
        XCTAssertFalse(pointerIsNear(markerScreenPoint))
        let windowsBeforeHover = visibleAppWindowIDs()
        let timingProbeFinished = DispatchSemaphore(value: 0)
        var hoverStartedAt: Date?
        var hintAppearedAt: Date?
        DispatchQueue.global(qos: .userInitiated).async {
            hoverStartedAt = waitForPointer(at: markerScreenPoint, timeout: 5)
            if let hoverStartedAt {
                let deadline = hoverStartedAt.addingTimeInterval(1)
                while Date() < deadline {
                    if !visibleAppWindowIDs().subtracting(windowsBeforeHover).isEmpty {
                        hintAppearedAt = Date()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            timingProbeFinished.signal()
        }
        seededMarkerCenter.hover()
        XCTAssertEqual(timingProbeFinished.wait(timeout: .now() + 5), .success)
        let confirmedHoverStart = try XCTUnwrap(hoverStartedAt, "Native hover must reach the comment glyphs.")
        let confirmedHintAppearance = try XCTUnwrap(hintAppearedAt, "The timing probe must observe the hint window.")
        XCTAssertGreaterThanOrEqual(confirmedHintAppearance.timeIntervalSince(confirmedHoverStart), 0.19,
                                    "The hint should wait about 200 ms after pointer entry.")
        XCTAssertTrue(seededCommentHint.waitToExist(timeout: 5),
                      "A native pointer hover on the comment glyphs should open their hint.")
        XCTAssertFalse(visibleAppWindowIDs().subtracting(windowsBeforeHover).isEmpty,
                       "The visible hint should create a window detectable by the timing probe.")
        attachScreenshot(named: "Focused seeded response comment hover popover")
        XCTAssertTrue(seededCommentHint.label.contains("legacy highlighted words"))
        XCTAssertTrue(seededCommentHint.label.contains(legacyComment))
        let seededMarkerScreenCenterX = seededLegacyLink.frame.minX + seededLegacyLink.frame.width * seededMarkerPointX
        XCTAssertLessThanOrEqual(seededCommentHint.frame.maxY, seededLegacyLink.frame.minY + 4,
                                 "The comment hint should open above its anchor text.")
        XCTAssertLessThanOrEqual(abs(seededCommentHint.frame.midX - seededMarkerScreenCenterX), 16,
                                 "The comment hint should be horizontally aligned to the hovered comment label.")
        offCommentCoordinate.hover()
        XCTAssertTrue(waitUntil({ !seededCommentHint.exists }, timeout: 0.2), "The comment hint should close as soon as the pointer leaves its link.")
        XCTAssertTrue(pointerIsNear(offCommentPoint), "The cancellation probe must start outside the link.")
        XCTAssertFalse(pointerIsNear(markerScreenPoint))
        let windowsBeforeBriefHover = visibleAppWindowIDs()
        let cancellationProbeFinished = DispatchSemaphore(value: 0)
        var cancelHoverStartedAt: Date?
        var pointerLeftAt: Date?
        var pointerWarpResult: CGError?
        var hintWindowAfterExit = false
        var pointerStayedOutside = false
        DispatchQueue.global(qos: .userInitiated).async {
            cancelHoverStartedAt = waitForPointer(at: markerScreenPoint, timeout: 5)
            if cancelHoverStartedAt != nil {
                Thread.sleep(forTimeInterval: 0.04)
                pointerWarpResult = CGWarpMouseCursorPosition(offCommentPoint)
                pointerLeftAt = Date()
                Thread.sleep(forTimeInterval: 0.25)
                pointerStayedOutside = pointerIsNear(offCommentPoint)
                hintWindowAfterExit = !visibleAppWindowIDs().subtracting(windowsBeforeBriefHover).isEmpty
            }
            cancellationProbeFinished.signal()
        }
        seededMarkerCenter.hover()
        XCTAssertEqual(cancellationProbeFinished.wait(timeout: .now() + 5), .success)
        let confirmedBriefHoverStart = try XCTUnwrap(cancelHoverStartedAt, "Brief hover must reach the comment glyphs.")
        let confirmedPointerExit = try XCTUnwrap(pointerLeftAt, "The pointer must leave the comment link.")
        XCTAssertLessThan(confirmedPointerExit.timeIntervalSince(confirmedBriefHoverStart), 0.2,
                          "The pointer must leave before the hover delay expires.")
        XCTAssertEqual(pointerWarpResult, .success)
        XCTAssertTrue(pointerStayedOutside, "The pointer should remain outside the comment after exit.")
        XCTAssertFalse(hintWindowAfterExit, "A brief hover should not create a late hint window.")
        XCTAssertFalse(seededCommentHint.exists, "A brief hover should not show a late hint after exit.")
        let paddedHoverProbeYs = [seededLegacyLink.frame.minY + 2, seededLegacyLink.frame.maxY - 4]
        XCTAssertLessThan(paddedHoverProbeYs[0], visibleMarkerTopY,
                          "The upper probe should be in the transparent inset above blue text.")
        XCTAssertGreaterThan(paddedHoverProbeYs[1], visibleMarkerBottomY,
                             "The lower probe should be in the transparent inset below blue text.")
        for edgeY in paddedHoverProbeYs {
            XCTAssertTrue(seededLegacyLink.frame.minY < edgeY && edgeY < seededLegacyLink.frame.maxY,
                          "The padded hover probe should remain inside the text view.")
            seededMarkerCenter.withOffset(CGVector(dx: visibleMarkerMidX - markerScreenPoint.x,
                                                   dy: edgeY - markerScreenPoint.y)).hover()
            XCTAssertTrue(waitUntil({ seededCommentHint.exists }, timeout: 5),
                          "The transparent text-view inset should trigger the comment hint.")
            offCommentCoordinate.hover()
            XCTAssertTrue(waitUntil({ !seededCommentHint.exists }, timeout: 0.2),
                          "The comment hint should close after leaving its label.")
        }

        attachScreenshot(named: "Comment test conversation before hover")
        let conversationHierarchy = XCTAttachment(string: app.debugDescription)
        conversationHierarchy.name = "Comment test conversation accessibility hierarchy"
        conversationHierarchy.lifetime = .keepAlways
        add(conversationHierarchy)
        XCTAssertTrue(revealWholeTranscript(), "The source turn should load as the reader scrolls up.")
        let userView = element("user-message-\(sourceID)")
        XCTAssertTrue(scrollTranscriptUntilExists(userView))
        let transcriptScrollView = element("conversation-scroll-view")
        for _ in 0..<4 where userView.frame.midY < transcriptScrollView.frame.minY + 20 {
            transcriptScrollView.swipeDown()
        }
        XCTAssertTrue(userView.frame.midY > transcriptScrollView.frame.minY + 20,
                      "The earlier user message should be visible before selecting its text.")
        let userBubbleScreenshot = userView.screenshot()
        let userBubbleAttachment = XCTAttachment(screenshot: userBubbleScreenshot)
        userBubbleAttachment.name = "User message bubble element"
        userBubbleAttachment.lifetime = .keepAlways
        add(userBubbleAttachment)
        assertGrayBorderedUserBubble(userBubbleScreenshot.image)
        attachScreenshot(named: "User message gray bordered bubble")
        func selectPrefix(_ view: XCUIElement) {
            // On the text itself: the bubble's padding around it takes no clicks.
            let text = view.textViews.firstMatch.exists ? view.textViews.firstMatch : view
            text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 9)).doubleClick()
        }
        func selectAllText(_ view: XCUIElement) {
            view.click()
            view.typeKey("a", modifierFlags: .command)
        }
        let userText = userView.textViews.firstMatch
        XCTAssertTrue(userText.exists, "The user message should expose its selectable text.")
        selectAllText(userView)
        XCTAssertGreaterThan(userView.frame.height, 40, "The selected text should wrap across multiple lines.")
        let initialBubble = try waitForSideChatBubble(at: userText, centered: true)
        XCTAssertFalse(app.buttons["add-comment-to-selection-button"].exists, "The side chat bubble replaces the Add comment hint.")
        let initialCommentField = element("side-chat-input")
        XCTAssertTrue(initialCommentField.waitToExist(timeout: 5))
        initialCommentField.typeText("Discard this comment")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(initialBubble.waitForNonExistence(timeout: 5), "Escape should close the side chat bubble.")
        XCTAssertFalse(element("send-message-button").isEnabled, "Closing the bubble should leave no pending comment to submit.")

        for (sourceView, comment, selectAll) in [
            (userView, "Explain this phrase", false),
            (element("assistant-message-\(assistantID)").descendants(matching: .staticText).firstMatch,
             String(repeating: "Please clarify this response in detail, including how each part connects to the question. ", count: 8), true),
        ] {
            XCTAssertTrue(sourceView.waitToExist(timeout: 5))
            let orangePixelsBefore = orangePixelCount(in: sourceView.screenshot())
            if selectAll {
                assistantSelection = (sourceView.value as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(assistantSelection.isEmpty, "The assistant paragraph should expose its selectable text.")
                selectAllText(sourceView)
            } else {
                selectPrefix(sourceView)
            }
            let bubble = try waitForSideChatBubble(at: sourceView)
            let field = element("side-chat-input")
            XCTAssertTrue(field.waitToExist(timeout: 5))
            let submitComment = element("add-comment-button")
            XCTAssertTrue(submitComment.exists, "The side chat composer should include its Comment button.")
            XCTAssertEqual(submitComment.label, "Comment")
            // Typing the long comment would take most of the case's time budget.
            if comment.count > 100 { pasteText(comment, into: field) } else { field.typeText(comment) }
            if comment == "Explain this phrase" {
                attachScreenshot(named: "Side chat bubble with a comment typed before Add comment")
            }
            // Add comment works on both message kinds and never sends the text to the side chat.
            submitComment.click()
            XCTAssertFalse(element("side-chat-user-message-0").exists, "Add comment must not send the text to the side chat.")
            XCTAssertTrue(bubble.waitForNonExistence(timeout: 5), "Add comment should add the comment and close the bubble.")
            XCTAssertTrue(element("send-message-button").isEnabled, "A comment without freeform text should enable sending.")
            let expectedCountLabel = comment == "Explain this phrase" ? "1 comment" : "2 comments"
            XCTAssertTrue(waitUntil({
                self.accessibleLabelOrValue(of: self.element("pending-comment-count")).contains(expectedCountLabel)
            }, timeout: 5), "The composer should indicate the number of pending comments.")
            let orangePixelsAfter = orangePixelCount(in: sourceView.screenshot())
            XCTAssertGreaterThan(orangePixelsAfter, orangePixelsBefore + 5, "The selected range should visibly render in orange.")
            XCTAssertLessThan(orangePixelFillRatio(in: sourceView.screenshot()), 0.55,
                              "Orange should cover the glyphs, not form a selection background marker.")
        }
        XCTAssertGreaterThan(orangePixelCount(in: userView.screenshot()), 5,
                             "Adding a second comment should preserve the first orange comment highlight.")
        let commentModeMenu = element("conversation-mode-menu")
        commentModeMenu.click()
        app.menuItems["conversation-mode-goal"].click()
        XCTAssertTrue(commentModeMenu.label.contains("Goal"), "The composer should enter Goal mode before sending pending comments.")
        let composer = app.textViews["message-composer"]
        XCTAssertTrue(composer.waitToExist(timeout: 5))
        composer.click()
        composer.typeText("Keep this freeform follow-up.")
        XCTAssertTrue((composer.value as? String ?? "").contains("Keep this freeform follow-up."),
                      "The freeform follow-up should be present in the editable composer before sending.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ !self.element("conversation-mode-menu").label.contains("Goal") }, timeout: 5),
                      "Sending pending comments should exit temporary Goal-entry mode.")
        let goalQueryResponse = try runCLI(["conversation", "goal", taskID, "get"])
        XCTAssertEqual(goalQueryResponse["ok"] as? Bool, true, "The Goal query should succeed: \(goalQueryResponse)")
        let goalAfterCommentSubmission = goalQueryResponse["result"]
        XCTAssertTrue(goalAfterCommentSubmission == nil || goalAfterCommentSubmission is NSNull,
                      "Submitting pending comments in Goal mode should not create a Goal from the serialized comment payload. Response: \(goalQueryResponse)")
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) ?? "").contains("Keep this freeform follow-up.")
        }, timeout: 10))
        let savedPrompt = try XCTUnwrap(taskRecord(id: taskID)?["savedPrompt"] as? String)
        let firstComment = try XCTUnwrap(savedPrompt.range(of: "Explain this phrase"))
        let secondComment = try XCTUnwrap(savedPrompt.range(of: "Please clarify this response in detail"))
        XCTAssertLessThan(firstComment.lowerBound, secondComment.lowerBound, "Comments should be sent in the order they were added.")
        XCTAssertTrue(savedPrompt.contains("\"messageId\":\"\(sourceID)\""))
        XCTAssertTrue(savedPrompt.contains("\"messageId\":\"\(assistantID)\""))
        XCTAssertTrue(savedPrompt.contains("\"startOffset\":0"))
        XCTAssertTrue(savedPrompt.contains("\"endOffset\":4"))
        XCTAssertTrue(savedPrompt.contains("\"text\":\"\(userSelection)\""))
        XCTAssertTrue(savedPrompt.contains("\"text\":\"\(assistantSelection)\""))
        XCTAssertTrue(savedPrompt.contains("\"comment\":\"Explain this phrase\""))
        XCTAssertTrue(savedPrompt.contains("start a separate response line with :playhouse-annotation{index=\"N\"}"))
        XCTAssertTrue(savedPrompt.contains("Do not combine comment responses on one line"))
        XCTAssertTrue(waitUntil({
            guard (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" else { return false }
            guard let history = try? self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any],
                  let messages = history["messages"] as? [[String: Any]],
                  let finalReply = self.ordinaryMessages(messages).last(where: { ($0["role"] as? String) == "assistant" }) else { return false }
            return (finalReply["text"] as? String ?? "").contains(":playhouse-annotation{index=\"1\"}")
        }, timeout: 60), "The fixture turn should finish before reopening to verify persisted comments.")
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Comment source")
        let reloadedHistory = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let reloadedMessages = try XCTUnwrap(reloadedHistory?["messages"] as? [[String: Any]])
        let annotatedUserMessage = try XCTUnwrap(ordinaryMessages(reloadedMessages).last { $0["role"] as? String == "user" })
        let annotatedUserID = try XCTUnwrap(annotatedUserMessage["id"] as? String)
        let annotatedAssistantMessage = try XCTUnwrap(ordinaryMessages(reloadedMessages).last { $0["role"] as? String == "assistant" })
        let annotatedAssistantID = try XCTUnwrap(annotatedAssistantMessage["id"] as? String)
        let restoredLegacyAssistant = try XCTUnwrap(reloadedMessages.first {
            ($0["role"] as? String) == "assistant" && (($0["text"] as? String)?.contains("legacy highlighted words") ?? false)
        })
        let restoredLegacyAssistantID = try XCTUnwrap(restoredLegacyAssistant["id"] as? String)
        let restoredUserView = element("user-message-\(sourceID)")
        let restoredAssistantView = element("assistant-message-\(assistantID)").descendants(matching: .staticText).firstMatch
        let renderedAnnotatedUserView = element("user-message-\(annotatedUserID)")
        let renderedCommentResponse = element("assistant-message-\(annotatedAssistantID)")
        let reloadedTranscript = element("conversation-scroll-view")
        XCTAssertTrue(renderedCommentResponse.waitToExist(timeout: 10),
                      "The reloaded conversation should finish loading before scrolling through history.")
        // Scroll up only until both restored messages sit where the checks below
        // need them; a fixed swipe count kept scrolling past the top.
        func restoredSourceTurnIsInView() -> Bool {
            restoredUserView.exists && restoredAssistantView.exists
                && restoredUserView.frame.minY >= reloadedTranscript.frame.minY + 8
                && restoredAssistantView.frame.minY < reloadedTranscript.frame.maxY - 40
        }
        for _ in 0..<6 where !restoredSourceTurnIsInView() {
            reloadedTranscript.swipeDown()
        }
        XCTAssertTrue(restoredUserView.waitToExist(timeout: 10))
        XCTAssertGreaterThanOrEqual(restoredUserView.frame.minY, reloadedTranscript.frame.minY + 8)
        XCTAssertLessThan(restoredUserView.frame.minY, reloadedTranscript.frame.maxY - 40)
        XCTAssertTrue(accessibleLabelOrValue(of: restoredUserView).contains("Literal # Response comments: stays visible."),
                      "Ordinary user text that resembles the comment heading should remain visible.")
        XCTAssertGreaterThan(orangePixelCount(in: restoredUserView.screenshot()), 5, "Reloading history should restore the user's orange range.")
        XCTAssertTrue(restoredAssistantView.waitToExist(timeout: 10))
        XCTAssertGreaterThanOrEqual(restoredAssistantView.frame.minY, reloadedTranscript.frame.minY + 8)
        XCTAssertLessThan(restoredAssistantView.frame.minY, reloadedTranscript.frame.maxY - 40)
        XCTAssertGreaterThan(orangePixelCount(in: restoredAssistantView.screenshot()), 5, "Reloading history should restore the assistant's orange range.")
        let legacyResponse = element("assistant-message-\(restoredLegacyAssistantID)")
        let legacyCommentLink = legacyResponse.descendants(matching: .staticText).matching(
            NSPredicate(format: "value CONTAINS %@", "Comment 1")
        ).firstMatch
        XCTAssertTrue(legacyCommentLink.waitToExist(timeout: 5))
        for _ in 0..<10 where legacyCommentLink.frame.maxY > reloadedTranscript.frame.maxY - 8 {
            reloadedTranscript.scroll(byDeltaX: 0, deltaY: -80)
        }
        XCTAssertGreaterThanOrEqual(legacyCommentLink.frame.minY, reloadedTranscript.frame.minY + 8)
        XCTAssertLessThanOrEqual(legacyCommentLink.frame.maxY, reloadedTranscript.frame.maxY - 8)
        legacyCommentLink.coordinate(withNormalizedOffset: CGVector(dx: seededMarkerPointX, dy: 0.8)).hover()
        XCTAssertTrue(element("response-comment-hover-card").waitToExist(timeout: 5),
                      "Older saved comment payloads should still restore reply details.")
        XCTAssertTrue(element("response-comment-hover-card").label.contains("legacy highlighted words"))
        XCTAssertTrue(element("response-comment-hover-card").label.contains(legacyComment))
        XCTAssertTrue(renderedAnnotatedUserView.waitToExist(timeout: 10))
        XCTAssertTrue(renderedCommentResponse.waitToExist(timeout: 10), "The comment reply should render after history reload.")
        for _ in 0..<25 where renderedAnnotatedUserView.frame.maxY > reloadedTranscript.frame.maxY - 8 {
            reloadedTranscript.scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertGreaterThanOrEqual(renderedAnnotatedUserView.frame.minY, reloadedTranscript.frame.minY + 8)
        XCTAssertLessThanOrEqual(renderedAnnotatedUserView.frame.maxY, reloadedTranscript.frame.maxY - 8)
        let renderedCommentText = accessibleLabelOrValue(of: renderedAnnotatedUserView)
        XCTAssertTrue(renderedCommentText.contains("Keep this freeform follow-up."), "Ordinary composer text should remain visible.")
        XCTAssertFalse(renderedCommentText.contains("Response comments"), "Comment guidance should be hidden in the transcript.")
        XCTAssertFalse(renderedCommentText.contains("<response-comments>"), "The comment payload should be hidden in the transcript.")
        XCTAssertFalse(renderedCommentText.contains("Explain this phrase"), "Comment details should be hidden in the transcript.")
        func revealReplyMarker(_ line: XCUIElement, verticalOffset: CGFloat) {
            func markerY() -> CGFloat {
                line.frame.minY + line.frame.height * verticalOffset
            }
            for _ in 0..<25 {
                let viewport = reloadedTranscript.frame
                let targetY = markerY()
                if targetY < viewport.minY + 24 {
                    reloadedTranscript.scroll(byDeltaX: 0, deltaY: min(80, viewport.minY + 24 - targetY))
                } else if targetY > viewport.maxY - 24 {
                    reloadedTranscript.scroll(byDeltaX: 0, deltaY: -min(80, targetY - viewport.maxY + 24))
                } else {
                    break
                }
            }
            XCTAssertGreaterThanOrEqual(markerY(), reloadedTranscript.frame.minY + 16)
            XCTAssertLessThanOrEqual(markerY(), reloadedTranscript.frame.maxY - 16)
        }
        // The reply's prose is one selectable text; each response line is its own paragraph in it.
        let responseTexts = renderedCommentResponse.descendants(matching: .staticText).allElementsBoundByIndex
        XCTAssertEqual(responseTexts.count, 1, "The reply's lines should share one selectable text.")
        let assistantResponseLines = (responseTexts.first?.value as? String ?? "").components(separatedBy: "\n")
        XCTAssertEqual(assistantResponseLines.count, 2, "Each comment response should render on its own line.")
        XCTAssertTrue(assistantResponseLines[0].hasPrefix("1. "), "The first response should begin with its numbered comment link.")
        XCTAssertTrue(assistantResponseLines[1].hasPrefix("2. "), "The second response should begin with its numbered comment link.")
        XCTAssertFalse(assistantResponseLines.joined(separator: "\n").contains(":playhouse-annotation"),
                       "Protocol markers should be replaced by visible comment labels.")
        let firstMarkerCenterX = "1.".size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width / 2
        func responseLine(_ prefix: String) -> XCUIElement {
            renderedCommentResponse.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "assistant-markdown-paragraph-", prefix
            )).firstMatch
        }
        let firstResponseLine = responseLine("1. ")
        revealReplyMarker(firstResponseLine, verticalOffset: 0.5)
        let markerPoint = firstResponseLine.coordinate(withNormalizedOffset: CGVector(
            dx: max(0.01, firstMarkerCenterX / max(1, firstResponseLine.frame.width)), dy: 0.5
        ))
        markerPoint.hover()
        let commentHint = element("response-comment-hover-card")
        XCTAssertTrue(commentHint.waitToExist(timeout: 5), "Hovering the first comment number should open its details hint.")
        attachScreenshot(named: "First response comment hover popover")
        XCTAssertEqual(commentHint.frame.width, 320, accuracy: 2, "The details hint is 320 points wide: wide enough to read both fields, still medium-sized.")
        XCTAssertTrue(commentHint.label.contains(userSelection),
                      "The hint should identify the highlighted text.")
        XCTAssertTrue(commentHint.label.contains("Explain this phrase"),
                         "The hint should show the user's comment.")
        let firstOffComment = firstResponseLine.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        for _ in 0..<2 {
            firstOffComment.hover()
            XCTAssertTrue(waitUntil({ !commentHint.exists }, timeout: 1))
            markerPoint.hover()
            XCTAssertTrue(waitUntil({ commentHint.exists && commentHint.label.contains("Explain this phrase") }, timeout: 5),
                          "The first comment link should reliably reopen after pointer reentry.")
        }
        let secondResponseLine = responseLine("2. ")
        XCTAssertGreaterThan(secondResponseLine.frame.height, 40,
                             "The second response should wrap while its numbered link stays at the start.")
        revealReplyMarker(secondResponseLine, verticalOffset: 0.03)
        let screenFrame = try XCTUnwrap(NSScreen.main?.frame)
        let screenImage = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ))
        let screenBitmap = NSBitmapImageRep(cgImage: screenImage)
        let pixelsPerPointX = CGFloat(screenBitmap.pixelsWide) / screenFrame.width
        let pixelsPerPointY = CGFloat(screenBitmap.pixelsHigh) / screenFrame.height
        let visibleLine = secondResponseLine.frame.intersection(reloadedTranscript.frame)
        XCTAssertFalse(visibleLine.isNull)
        let pixelMinX = max(0, Int(visibleLine.minX * pixelsPerPointX))
        let pixelMaxX = min(screenBitmap.pixelsWide - 1, Int(visibleLine.maxX * pixelsPerPointX))
        let pixelMinY = max(0, Int(visibleLine.minY * pixelsPerPointY))
        let pixelMaxY = min(screenBitmap.pixelsHigh - 1, Int(visibleLine.maxY * pixelsPerPointY))
        var secondBlueMinX = screenBitmap.pixelsWide
        var secondBlueMaxX = -1
        var secondBlueMinY = screenBitmap.pixelsHigh
        var secondBlueMaxY = -1
        for x in pixelMinX...pixelMaxX {
            for y in pixelMinY...pixelMaxY {
                guard let color = screenBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > 0.6 && color.blueComponent > color.redComponent + 0.25
                    && color.blueComponent > color.greenComponent + 0.08 {
                    secondBlueMinX = min(secondBlueMinX, x)
                    secondBlueMaxX = max(secondBlueMaxX, x)
                    secondBlueMinY = min(secondBlueMinY, y)
                    secondBlueMaxY = max(secondBlueMaxY, y)
                }
            }
        }
        XCTAssertGreaterThan(secondBlueMaxX, secondBlueMinX, "The visible wrapped reply should contain blue 2. glyphs.")
        let secondMarkerX = CGFloat(secondBlueMinX + secondBlueMaxX) / 2 / pixelsPerPointX
        let secondMarkerY = CGFloat(secondBlueMinY + secondBlueMaxY) / 2 / pixelsPerPointY
        let secondMarkerOffset = CGVector(
            dx: (secondMarkerX - secondResponseLine.frame.minX) / secondResponseLine.frame.width,
            dy: (secondMarkerY - secondResponseLine.frame.minY) / secondResponseLine.frame.height
        )
        let secondMarkerPoint = secondResponseLine.coordinate(withNormalizedOffset: secondMarkerOffset)
        secondMarkerPoint.hover()
        XCTAssertTrue(waitUntil({ commentHint.exists && commentHint.label.contains("Please clarify this response") }, timeout: 5),
                      "Hovering the second comment number should open its own details hint.")
        attachScreenshot(named: "Second response comment hover popover")
        XCTAssertLessThanOrEqual(commentHint.frame.height, 240, "Long comment details should remain within a medium-sized hint.")
        XCTAssertTrue(commentHint.label.contains(String(assistantSelection.prefix(30))),
                      "Long highlighted text should remain identifiable in the hint.")
        XCTAssertTrue(commentHint.label.contains("Please clarify this response"),
                      "Long comment details should remain identifiable when truncated.")
        let offComment = secondResponseLine.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: secondMarkerOffset.dy))
        for _ in 0..<2 {
            offComment.hover()
            XCTAssertTrue(waitUntil({ !commentHint.exists }, timeout: 1),
                          "The hint should close before hovering another comment.")
            secondMarkerPoint.hover()
            XCTAssertTrue(waitUntil({ commentHint.exists && commentHint.label.contains("Please clarify this response") }, timeout: 5),
                          "The second comment link should reliably reopen after pointer reentry.")
        }
        offComment.hover()
        XCTAssertTrue(waitUntil({ !commentHint.exists }, timeout: 1))

        let emptyComposer = element("message-composer")
        XCTAssertTrue((emptyComposer.value as? String ?? "").isEmpty)
        // Selecting all of the reply's text spans both response paragraphs, so this comment
        // covers more than one block.
        // Each paragraph is measured fully on screen: the pending-comment chip grows the composer,
        // which can cover the end of the reply.
        func orangePixels(in line: XCUIElement) -> Int {
            XCTAssertTrue(scrollFullyIntoView(line, in: reloadedTranscript), "The reply paragraph should scroll fully into view.")
            return orangePixelCount(in: line.screenshot())
        }
        let firstLineOrangeBefore = orangePixels(in: firstResponseLine)
        let secondLineOrangeBefore = orangePixels(in: secondResponseLine)
        secondResponseLine.click()
        secondResponseLine.typeKey("a", modifierFlags: .command)
        // The selection starts in the first paragraph, which can be scrolled above the
        // transcript; the bubble then opens at the selection's visible part.
        let commentOnlyBubble = try waitForSideChatBubble()
        XCTAssertTrue(commentOnlyBubble.isHittable, "The side chat bubble should open on screen when the selection starts above the visible transcript.")
        let transcriptFrame = reloadedTranscript.frame
        // The bubble opens above the anchor, or below it without room, so one of its edges meets
        // the selection's visible part, inside the transcript.
        XCTAssertTrue([commentOnlyBubble.frame.minY, commentOnlyBubble.frame.maxY].contains { $0 >= transcriptFrame.minY - 40 && $0 <= transcriptFrame.maxY + 40 },
                      "The bubble should point at the selection's visible part, inside the transcript (bubble \(commentOnlyBubble.frame), transcript \(transcriptFrame)).")
        let commentOnlyField = element("side-chat-input")
        XCTAssertTrue(commentOnlyField.waitToExist(timeout: 5))
        commentOnlyField.typeText("Explain this reply")
        element("add-comment-button").click()
        XCTAssertTrue(commentOnlyBubble.waitForNonExistence(timeout: 5), "Add comment should close the bubble.")
        XCTAssertTrue(element("pending-comment-count").waitToExist(timeout: 5), "The comment-only selection should become a pending comment.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("pending-comment-count")).contains("1 comment"),
                      "A selection across paragraphs should add one comment, not one per paragraph.")
        XCTAssertGreaterThan(orangePixels(in: firstResponseLine), firstLineOrangeBefore + 5,
                             "A comment across paragraphs should highlight its first paragraph.")
        XCTAssertGreaterThan(orangePixels(in: secondResponseLine), secondLineOrangeBefore + 5,
                             "A comment across paragraphs should highlight its last paragraph.")
        attachScreenshot(named: "Comment spanning two reply paragraphs")
        XCTAssertTrue((emptyComposer.value as? String ?? "").isEmpty)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard let history = try? self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any],
                  let messages = history["messages"] as? [[String: Any]],
                  let answer = self.ordinaryMessages(messages).last(where: { ($0["role"] as? String) == "assistant" }) else { return false }
            return (answer["id"] as? String) != annotatedAssistantID
                && (answer["text"] as? String ?? "").contains(":playhouse-annotation{index=\"0\"}")
        }, timeout: 20), "A comment-only turn should reach the provider and produce a linked reply.")
        let commentOnlyHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let commentOnlyMessages = try XCTUnwrap(commentOnlyHistory["messages"] as? [[String: Any]])
        let commentOnlyRequest = try XCTUnwrap(ordinaryMessages(commentOnlyMessages).last(where: { ($0["role"] as? String) == "user" }))
        let commentOnlyPayload = try XCTUnwrap(commentOnlyRequest["text"] as? String)
        XCTAssertTrue(commentOnlyPayload.hasPrefix("<playhouse-comment-context>"),
                      "An empty-composer send should contain only the structured comment context.")
        XCTAssertTrue(commentOnlyPayload.contains("Explain this reply"))
        let spanningPayload = try XCTUnwrap(commentOnlyPayload.components(separatedBy: "<response-comments>").last?
            .components(separatedBy: "</response-comments>").first)
        let spanningComments = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(spanningPayload.utf8)) as? [[String: Any]])
        XCTAssertEqual(spanningComments.count, 1, "A selection across paragraphs should send one comment.")
        let spanningSource = try XCTUnwrap(spanningComments.first?["source"] as? [String: Any])
        XCTAssertEqual(spanningSource["messageId"] as? String, annotatedAssistantID)
        let spanningStartBlock = try XCTUnwrap(spanningSource["blockID"] as? Int)
        let spanningEndBlock = try XCTUnwrap(spanningSource["endBlockID"] as? Int,
                                             "A comment across paragraphs should record the block it ends in.")
        XCTAssertLessThan(spanningStartBlock, spanningEndBlock)
        XCTAssertEqual(spanningSource["startOffset"] as? Int, 0)
        let spanningText = try XCTUnwrap(spanningComments.first?["text"] as? String)
        XCTAssertTrue(spanningText.contains("1. ") && spanningText.contains("2. "),
                      "The commented text should include both paragraphs.")

        // The cross-paragraph highlight is restored from the sent payload after reopening.
        element("back-to-board-button").click()
        openTask(named: "Comment source")
        // Reopening shows only the newest turn; the commented reply is in an earlier one.
        XCTAssertTrue(waitUntil({ firstResponseLine.exists }, timeout: 5) || revealWholeTranscript(),
                      "The commented reply should render after reopening.")
        // Earlier rows render only near the viewport, so bring the reply back into view.
        XCTAssertTrue(scrollTranscriptUntilExists(firstResponseLine), "The commented reply should be reachable after reopening.")
        XCTAssertGreaterThan(orangePixels(in: firstResponseLine), firstLineOrangeBefore + 5,
                             "Reopening should restore the cross-paragraph highlight on its first paragraph.")
        XCTAssertGreaterThan(orangePixels(in: secondResponseLine), secondLineOrangeBefore + 5,
                             "Reopening should restore the cross-paragraph highlight on its last paragraph.")
        attachScreenshot(named: "Restored comment spanning two reply paragraphs")
    }
    // case-contract: test_side_chat_forks_claude_conversation_read_only | Selecting text in a Claude task's reply shows a Side chat hint centered above the selection, and no bubble opens until it is clicked; clicking it hides the hint and opens a side chat bubble above the selection that starts compact and grows to wrap its conversation, wider once it has messages and taller with each exchange, until the chat reaches its maximum height and scrolls. The bubble shows the selected text and a compact chat with no subtitle, whose composer has a Comment button, the conversation's model picker and a send button but no Skills button or mode menu. Choosing another model and effort in the bubble applies to the side chat's next messages only: the task keeps its own model. The first side chat message forks the task's Claude session with --resume and --fork-session under a new session ID, read-only (Edit, MultiEdit, Write and NotebookEdit disallowed), with side chat instructions that list the Playhouse CLI and forbid reporting the task's progress or outcome, and the selected text quoted in the prompt; its answer streams and shows the source session's context in the bubble. A follow-up resumes the forked session without forking again, with the model and effort chosen for it. Asking it to create a task lets only the Playhouse CLI's board commands run, checked by a PreToolUse hook Playhouse passes in the launch settings (ahead of the user's own allow rules) and by its permission handler: a Write, an ordinary shell command and the CLI chained with & to another command are denied, while the CLI's task create, whose quoted description contains shell punctuation, really creates the task, and no file is written. The task's own conversation, Claude session, status and history are unchanged by the side chat. A side chat needs a conversation to fork, a selection, a non-empty message and a valid model and effort; an unknown side chat rejects follow-ups, and closing the bubble with Escape ends its live session without adding a comment, while the saved side chat's next follow-up continues the same forked session.
    func test_side_chat_forks_claude_conversation_read_only() throws {
        _ = try installClaudeFixture(named: "claude-fixture-side-chat")
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        launchApp(defaultParent: fixture.parent.path)
        // The task runs on a model other than the default, so the side chat starting on it shows.
        var taskModelID = ""
        let opened = try openSideChatOnReply(title: "Claude side chat") { taskID in
            let models = try XCTUnwrap((try self.runCLI(["conversation", "models", taskID])["result"] as? [String: Any])?["models"] as? [[String: Any]])
            taskModelID = try XCTUnwrap(models.first { ($0["isDefault"] as? Bool) != true }?["id"] as? String, "The fixture should list a non-default model.")
            _ = try self.runCLI(["conversation", "model", taskID, "set", taskModelID])
        }
        let taskBefore = try XCTUnwrap(try taskRecord(id: opened.taskID))
        let historyBefore = try XCTUnwrap((try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        let selected = element("side-chat-selected-text")
        XCTAssertTrue(selected.waitToExist(timeout: 5))
        let selection = opened.reply.value as? String ?? ""
        XCTAssertFalse(selection.isEmpty, "The reply should expose its selectable text.")
        XCTAssertEqual((selected.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       selection.trimmingCharacters(in: .whitespacesAndNewlines), "The bubble should show the selected text.")
        XCTAssertFalse(opened.bubble.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Ask about the selected text")).firstMatch.exists,
                       "A new side chat shows no subtitle.")
        let compact = opened.bubble.frame
        XCTAssertLessThanOrEqual(compact.maxY, opened.reply.frame.minY + 4,
                                 "The bubble should open above the selected text (bubble \(compact), selection \(opened.reply.frame)).")
        XCTAssertLessThan(compact.width, 480, "A new side chat bubble should start compact (\(compact)).")
        XCTAssertLessThan(compact.height, 300, "A new side chat bubble should start compact (\(compact)).")
        let bubbleElements = opened.bubble.descendants(matching: .any)
        XCTAssertTrue(bubbleElements.matching(identifier: "add-comment-button").firstMatch.exists,
                      "The side chat composer should have a Comment button.")
        XCTAssertEqual(element("add-comment-button").label, "Comment", "The side chat's comment button is labelled Comment.")
        XCTAssertTrue(bubbleElements.matching(identifier: "side-chat-send-button").firstMatch.exists)
        XCTAssertFalse(bubbleElements.matching(identifier: "open-skills-button").firstMatch.exists,
                       "The side chat composer has no Skills button.")
        XCTAssertFalse(bubbleElements.matching(identifier: "conversation-mode-menu").firstMatch.exists,
                       "The side chat composer has no mode menu.")
        XCTAssertFalse(element("side-chat-send-button").isEnabled, "An empty side chat message can't be sent.")
        attachScreenshot(named: "Side chat bubble opened on the selected reply")

        let sourceSession = try XCTUnwrap(taskBefore["claudeSessionID"] as? String)
        let answer = sendSideChatMessage("What does this mean?", answerIndex: 1, containing: "forked from \(sourceSession)")
        XCTAssertTrue(answer.label.contains("which asked: Explain the design of the parser."),
                      "The side chat should answer with the task conversation's context.")
        XCTAssertTrue(waitUntil({ opened.bubble.frame.width > compact.width + 60 && opened.bubble.frame.height > compact.height + 40 }, timeout: 5),
                      "The bubble should grow to wrap the conversation (compact \(compact), now \(opened.bubble.frame)).")
        let afterFirstAnswer = opened.bubble.frame
        attachScreenshot(named: "Side chat answer with the task's context")
        // The bubble's own model picker: another model for the side chat, not for the task.
        let taskModelBefore = String(describing: try runCLI(["conversation", "model", opened.taskID])["result"] ?? "nil")
        let modelMenu = element("side-chat-model-picker-menu")
        XCTAssertTrue(modelMenu.waitToExist(timeout: 5), "The side chat composer should have a model picker.")
        XCTAssertTrue(opened.bubble.descendants(matching: .any).matching(identifier: "side-chat-model-picker-menu").firstMatch.exists)
        modelMenu.click()
        let otherModel = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@", "side-chat-model-option-", "Not selected"
        )).firstMatch
        XCTAssertTrue(element("side-chat-model-option-\(taskModelID)").waitToExist(timeout: 5), "The side chat model picker should open.")
        XCTAssertEqual(element("side-chat-model-option-\(taskModelID)").value as? String, "Selected",
                       "The side chat should start on the task's own model.")
        XCTAssertTrue(otherModel.waitToExist(timeout: 5), "The side chat model picker should list the provider's other models.")
        let chosenModelID = String(otherModel.identifier.dropFirst("side-chat-model-option-".count))
        otherModel.click()
        attachScreenshot(named: "Side chat model picker with another model chosen")
        modelMenu.click()
        XCTAssertTrue(waitUntil({ !self.element("side-chat-model-option-\(chosenModelID)").exists }, timeout: 5),
                      "The side chat model picker should close.")
        _ = sendSideChatMessage("And the second point?", answerIndex: 3, containing: "Side chat follow-up 2 on")
        let claudeHistory = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(claudeFixtureExecutable) + ".history"))) as? [String: Any]
        let followUpArguments = try XCTUnwrap(((claudeHistory?["turns"] as? [[String: Any]])?.last)?["arguments"] as? [String])
        let modelFlag = try XCTUnwrap(followUpArguments.firstIndex(of: "--model"), "The side chat should send its chosen model: \(followUpArguments)")
        XCTAssertEqual(followUpArguments[modelFlag + 1], chosenModelID, "The side chat should run its next message on the chosen model.")
        XCTAssertEqual(String(describing: try runCLI(["conversation", "model", opened.taskID])["result"] ?? "nil"), taskModelBefore,
                       "Choosing a model in the side chat must not change the task's model.")
        let created = sendSideChatMessage("Please create a task for this.", answerIndex: 5, containing: "Created task ")
        XCTAssertTrue(waitUntil({ opened.bubble.frame.height > afterFirstAnswer.height + 20 }, timeout: 5),
                      "The bubble should keep growing with each exchange (\(afterFirstAnswer) then \(opened.bubble.frame)).")
        // More exchanges than fit: the chat stops at its maximum height and scrolls.
        let transcript = element("side-chat-transcript")
        for index in stride(from: 7, through: 11, by: 2) {
            _ = sendSideChatMessage("Another point, number \(index)?", answerIndex: index, containing: "Side chat follow-up")
        }
        XCTAssertTrue(waitUntil({ (330...342).contains(transcript.frame.height) }, timeout: 5),
                      "A long side chat should reach the transcript's maximum height (\(transcript.frame)).")
        let capped = opened.bubble.frame
        let lastAnswer = sendSideChatMessage("One more point?", answerIndex: 13, containing: "Side chat follow-up")
        XCTAssertEqual(opened.bubble.frame.height, capped.height, accuracy: 2, "At its maximum the bubble stops growing.")
        XCTAssertTrue(waitUntil({ transcript.frame.contains(CGPoint(x: lastAnswer.frame.midX, y: lastAnswer.frame.maxY - 2)) }, timeout: 5),
                      "The newest answer should be scrolled into view (answer \(lastAnswer.frame), transcript \(transcript.frame)).")
        let firstQuestion = element("side-chat-user-message-0")
        XCTAssertLessThan(firstQuestion.frame.maxY, transcript.frame.minY + 1, "The first exchange should have scrolled out of view.")
        attachElementScreenshot(opened.bubble, named: "Side chat bubble at its maximum height, scrolled to the newest answer")
        XCTAssertTrue(waitUntil({
            transcript.scroll(byDeltaX: 0, deltaY: 400)
            return transcript.frame.contains(CGPoint(x: firstQuestion.frame.midX, y: firstQuestion.frame.midY))
        }, timeout: 5), "Scrolling the side chat up should bring back its first exchange.")
        let createdID = String(created.label.split(separator: " ").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let createdTask = try XCTUnwrap(try taskRecord(id: createdID), "The side chat should create a real task through the CLI.")
        XCTAssertEqual(createdTask["title"] as? String, "Side chat follow-up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.primary.appendingPathComponent("side-chat-forbidden.txt").path),
                       "The read-only side chat must not write files.")
        attachScreenshot(named: "Side chat created a task through the Playhouse CLI")
        attachElementScreenshot(opened.bubble, named: "Side chat bubble scrolled back to its first exchange")

        let taskAfter = try XCTUnwrap(try taskRecord(id: opened.taskID))
        XCTAssertEqual(taskAfter["status"] as? String, taskBefore["status"] as? String, "The side chat must not change the task's status.")
        XCTAssertEqual(taskAfter["claudeSessionID"] as? String, sourceSession, "The task keeps its own Claude session.")
        let historyAfter = try XCTUnwrap((try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertEqual(historyAfter.compactMap { $0["text"] as? String }, historyBefore.compactMap { $0["text"] as? String },
                       "The side chat's messages must not reach the task's conversation.")

        let sideChatID = element("side-chat-send-button").value as? String ?? ""
        XCTAssertFalse(sideChatID.isEmpty, "The bubble should name the side chat its first message opened.")
        // That side chat is live while the bubble is open, so the rejection after Escape is the close.
        let live = try XCTUnwrap(try runCLI(["conversation", "side-chat", opened.taskID, "--side-chat", sideChatID, "--message", "Still open?"])["result"] as? [String: Any])
        XCTAssertTrue((live["reply"] as? String ?? "").contains("Side chat follow-up"), "The bubble's side chat should still answer before it closes: \(live)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(opened.bubble.waitForNonExistence(timeout: 5), "Escape should close the side chat bubble.")
        XCTAssertFalse(element("send-message-button").isEnabled, "Closing the side chat adds no comment.")
        XCTAssertFalse(element("pending-comment-count").exists)
        attachScreenshot(named: "Side chat closed with Escape and no pending comment")
        // The bubble ends its live session as it goes away, in a request of its own; the side
        // chat stays saved, so its next message continues the same forked session.
        Thread.sleep(forTimeInterval: 1.5)
        let continued = try XCTUnwrap(try runCLI(["conversation", "side-chat", opened.taskID, "--side-chat", sideChatID, "--message", "Still there?"])["result"] as? [String: Any])
        let forkSession = try XCTUnwrap(((continued["sideChat"] as? [String: Any])?["threadID"]) as? String)
        XCTAssertNotEqual(forkSession, sourceSession)
        XCTAssertTrue((continued["reply"] as? String ?? "").hasSuffix("on \(forkSession): Still there?"),
                      "A closed side chat should continue its forked session: \(continued)")

        // Clicking its text, now side-chatted, reopens the bubble with the saved exchanges.
        clickHighlightedText(opened.reply)
        XCTAssertTrue(element("side-chat-bubble").waitToExist(timeout: 8), "Clicking side-chatted text should reopen its bubble.")
        XCTAssertEqual(element("side-chat-user-message-0").label, "What does this mean?")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("side-chat-bubble").waitForNonExistence(timeout: 5))
    }
    // case-contract: test_side_chat_forks_codex_conversation_read_only | The first side chat message on a Codex task's selected text forks the task's Codex thread with thread/fork into Codex's read-only sandbox (excluding turns from the response, with approvals off and the side chat developer instructions), and every side chat turn names a read-only sandbox policy with network access, so the Playhouse CLI still reaches the bridge daemon. The answer streams, names the forked source thread and quotes the selected text; a follow-up continues the same forked thread with the model and effort chosen for it, reloading the fork in the read-only sandbox when the model changes, and asking it to create a task really creates one through the CLI, run inside the read-only sandbox, where the daemon accepts only board requests from a sandboxed caller, so the same side chat's task delete is refused as forbidden and the task stays. The task's own conversation, Codex thread, status and history are unchanged. In the app the bubble opens on the selection, shows the question and the answer below the selected text, and a follow-up adds a second exchange. Closing a side chat keeps it saved, and its next follow-up continues the same forked thread.
    func test_side_chat_forks_codex_conversation_read_only() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success").path
        launchApp(defaultParent: fixture.parent.path)
        let opened = try openSideChatOnReply(title: "Codex side chat")
        let taskBefore = try XCTUnwrap(try taskRecord(id: opened.taskID))
        let sourceThread = try XCTUnwrap(taskBefore["codexThreadID"] as? String)
        let historyBefore = try XCTUnwrap((try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        let answer = sendSideChatMessage("What does this mean?", answerIndex: 1, containing: "forked from \(sourceThread): What does this mean?")
        XCTAssertTrue(answer.label.hasPrefix("Side chat about \""), "The answer should quote the selected text.")
        XCTAssertGreaterThan(answer.frame.minY, element("side-chat-selected-text").frame.maxY, "The answer should appear below the selected text.")
        attachScreenshot(named: "Codex side chat answer below the selected text")
        _ = sendSideChatMessage("And the second point?", answerIndex: 3, containing: "Side chat follow-up 2 on fork-")
        let created = sendSideChatMessage("Please create a task for this.", answerIndex: 5, containing: "Created task ")
        let createdID = String(created.label.split(separator: " ").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        XCTAssertEqual(try taskRecord(id: createdID)?["title"] as? String, "Side chat follow-up")
        attachScreenshot(named: "Codex side chat follow-ups")
        let sideChatID = element("side-chat-send-button").value as? String ?? ""
        XCTAssertFalse(sideChatID.isEmpty, "The bubble should name the side chat its first message opened.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(opened.bubble.waitForNonExistence(timeout: 5), "Escape should close the side chat bubble.")
        // Closing ends only the live session; the saved side chat continues the same forked thread.
        Thread.sleep(forTimeInterval: 1.5)
        let continued = try XCTUnwrap(try runCLI(["conversation", "side-chat", opened.taskID, "--side-chat", sideChatID, "--message", "Still there?"])["result"] as? [String: Any])
        let forkThread = try XCTUnwrap(((continued["sideChat"] as? [String: Any])?["threadID"]) as? String)
        XCTAssertTrue(forkThread.hasPrefix("fork-"), "The side chat should keep its forked thread: \(continued)")
        XCTAssertTrue((continued["reply"] as? String ?? "").hasSuffix("on \(forkThread): Still there?"),
                      "A closed side chat should continue its forked thread: \(continued)")
        let taskAfter = try XCTUnwrap(try taskRecord(id: opened.taskID))
        XCTAssertEqual(taskAfter["status"] as? String, taskBefore["status"] as? String)
        XCTAssertEqual(taskAfter["codexThreadID"] as? String, sourceThread, "The task keeps its own Codex thread.")
        let historyAfter = try XCTUnwrap((try runCLI(["conversation", "history", opened.taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertEqual(historyAfter.compactMap { $0["text"] as? String }, historyBefore.compactMap { $0["text"] as? String },
                       "The side chat's messages must not reach the task's conversation.")
    }
}

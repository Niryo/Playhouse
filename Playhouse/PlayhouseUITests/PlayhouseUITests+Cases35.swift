import AppKit
import Foundation
import XCTest

extension PlayhouseUITests {
    private static let parallelSaladPrompt = "Suggest a quick salad lunch."
    private static let parallelSaladAnswer = "A Greek salad takes ten minutes."
    private static let parallelSoupPrompt = "Suggest a quick soup supper."
    private static let parallelSoupAnswer = "Tomato soup takes twenty minutes."
    private static let parallelDressingPrompt = "Add a dressing."
    private static let parallelDressingAnswer = "Lemon and olive oil."
    private static let parallelJupiterPrompt = "Name the largest moon of Jupiter."
    private static let parallelJupiterAnswer = "Ganymede is the largest moon of Jupiter."
    private static let parallelPastaPrompt = "Suggest a quick pasta dinner."
    private static let parallelPastaAnswer = "Cacio e pepe takes fifteen minutes."
    private static let parallelTacoPrompt = "Suggest a quick taco breakfast."
    private static let parallelTacoAnswer = "Egg tacos take five minutes."

    /// The chat sidebar's own controls, apart from those of an opened bubble's conversation.
    private func chatSidebarElement(_ identifier: String) -> XCUIElement {
        element("chat-sidebar").descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func parallelPanelElement(_ identifier: String) -> XCUIElement {
        element("parallel-chat-panel").descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func parallelBubbles(environment: [String: String] = [:]) -> [[String: Any]] {
        ((try? runCLI(["chat", "bubble", "list"], extraEnvironment: environment))?["result"] as? [String: Any])?["bubbles"] as? [[String: Any]] ?? []
    }

    private func parallelHistoryTexts(_ taskID: String, environment: [String: String] = [:]) -> [String] {
        let history = (try? runCLI(["conversation", "history", taskID], extraEnvironment: environment))?["result"] as? [String: Any]
        return (history?["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    private func parallelChatPages(environment: [String: String] = [:]) -> [[String: Any]] {
        ((try? runCLI(["chat", "page", "list"], extraEnvironment: environment))?["result"] as? [String: Any])?["pages"] as? [[String: Any]] ?? []
    }

    /// Types `prompt` into the chat's composer and presses Send in parallel.
    private func sendInParallelFromChat(_ prompt: String, captureComposer: Bool = false) {
        let composer = chatSidebarElement("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15))
        composer.click()
        composer.typeText(prompt)
        let button = chatSidebarElement("composer-send-in-parallel-button")
        XCTAssertTrue(button.waitToExist(timeout: 5), "The chat offers Send in parallel beside Send.")
        XCTAssertTrue(waitUntil({ button.isEnabled }, timeout: 5))
        let send = chatSidebarElement("send-message-button")
        XCTAssertTrue(send.exists)
        XCTAssertEqual(button.frame.midY, send.frame.midY, accuracy: 2)
        let gap = button.frame.minX - send.frame.maxX
        XCTAssertGreaterThanOrEqual(gap, 0)
        XCTAssertLessThanOrEqual(gap, 8)
        XCTAssertLessThan(button.frame.width, send.frame.width)
        if captureComposer {
            attachAppWindowScreenshot(named: "parallel-send-beside-send")
            let icon = XCTAttachment(screenshot: button.screenshot())
            icon.name = "parallel-send-icon"
            icon.lifetime = .keepAlways
            add(icon)
        }
        button.click()
    }

    /// The bubble showing `prompt`, found by its open button's label.
    private func parallelBubbleButton(_ prompt: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "parallel-chat-bubble-open", prompt)).firstMatch
    }

    private func parallelBubbleClose(_ prompt: String) -> XCUIElement {
        let bubble = parallelBubbleButton(prompt)
        // The close button sits in the same bubble, level with its open button; the bubble shown
        // while a send starts has none, so it finds no close.
        guard bubble.exists else { return element("parallel-chat-bubble-close-of-missing-bubble") }
        let closes = app.descendants(matching: .any).matching(identifier: "parallel-chat-bubble-close").allElementsBoundByIndex
        return closes.first { abs($0.frame.midY - bubble.frame.midY) < 12 } ?? element("parallel-chat-bubble-close-of-missing-bubble")
    }

    private func parallelPlaceholder(_ prompt: String) -> XCUIElement {
        element("chat-sidebar").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "parallel-chat-placeholder-prompt", prompt, prompt)).firstMatch
    }

    private func openReturnedParallelPage(_ id: String, title: String) {
        let handle = element("chat-page-anchors-handle")
        XCTAssertTrue(handle.waitToExist(timeout: 10))
        handle.hover()
        let label = element("chat-page-anchor-\(id)")
        guard label.waitToExist(timeout: 10) else {
            XCTFail("The returned page \(title) has a label.")
            return
        }
        label.click()
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible(title) }, timeout: 15),
                      "Selecting the returned page shows its transcript separator.")
    }

    // case-contract: test_parallel_chat_bubble_runs_alongside_and_returns_to_its_placeholder | The standalone chat can ask a question in parallel: the CLI's chat bubble send, and in the chat the Send in parallel button beside Send, put the message on a new page of its own that runs in a parallel bubble, its own conversation with a fresh provider session that opens like a New page turn, while the chat itself stays free: a message sent in the chat while the bubble answers runs and finishes there at once. chat bubble list reports the bubble with its question, whether it is still answering, and the chat's turn that was last when it was sent; in the app the bubble floats out of the chat sidebar's right edge showing its question and a spinner, and the chat shows a small placeholder with the question where the bubble's page will return. Once answered, the bubble shows it is done and opens into a larger view of its own conversation, where a follow-up continues the bubble's page in the same provider session. Closing it removes the bubble and its placeholder and inserts the bubble's page, all its turns together, into the chat at that spot, keeping the chat's order by time without splitting a page: right after the turn that was last when it was sent, unless the chat went on with that turn's page, in which case it returns above that page, and never at or after the chat's current page. So a bubble sent on the current page returns above it, a bubble whose page the chat went on with and then left for a new page returns above that earlier page, and a bubble sent at the end of a page the chat then left returns between the two. The returned page belongs to the chat, is listed among the chat's pages in that place, its messages are filed on it, the page labels show it there and jumping to its label shows its window. Bubbles, placement and the merge are Playhouse-owned, and the bubble's turns run through the standalone chat's provider-neutral New page path, so one representative provider (Claude) covers the case.
    func test_parallel_chat_bubble_runs_alongside_and_returns_to_its_placeholder() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-parallel-bubbles")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(modelPrompt().waitToExist(timeout: 15), "The empty main chat should finish loading before typing.")
        let composer = element("chat-sidebar").textViews.matching(identifier: "message-composer").firstMatch
        let scrollView = element("chat-sidebar").descendants(matching: .scrollView).matching(identifier: "conversation-scroll-view").firstMatch

        func fixtureTurns(endingWith prompt: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter {
                let text = ($0["userText"] as? String) ?? ""
                return text.hasSuffix(prompt) && !text.hasPrefix("Classify the latest user message")
            }
        }
        /// Sends from the chat and waits for the chat itself to finish, whatever bubbles still run.
        func sendInChat(_ prompt: String, expecting texts: [String]) {
            XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The main chat composer should be hittable.")
            typeIntoField(composer, text: prompt)
            chatSidebarElement("send-message-button").click()
            XCTAssertTrue(waitUntil({
                self.parallelHistoryTexts(chatID) == texts && !self.chatSidebarElement("pause-response-button").exists
            }, timeout: 30), "The chat turn \(prompt) should finish: \(parallelHistoryTexts(chatID))")
        }
        func historyMessages() -> [[String: Any]] {
            ((try? runCLI(["conversation", "history", chatID]))?["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        }
        /// The chat's messages with this text, top to bottom.
        func chatMessages(_ text: String) -> [XCUIElement] {
            scrollView.descendants(matching: .group).matching(NSPredicate(format: "label == %@ AND (identifier BEGINSWITH %@ OR identifier BEGINSWITH %@)", text, "user-message-", "assistant-message-"))
                .allElementsBoundByIndex.filter(\.exists).sorted { $0.frame.minY < $1.frame.minY }
        }
        func closeOf(_ prompt: String) -> XCUIElement {
            XCTAssertTrue(waitUntil({ self.parallelBubbleClose(prompt).exists }, timeout: 15), "The bubble \(prompt) has its close button.")
            return parallelBubbleClose(prompt)
        }

        sendInChat(Self.parallelJupiterPrompt, expecting: [Self.parallelJupiterPrompt, Self.parallelJupiterAnswer])
        let jupiterPageID = try XCTUnwrap(((try runCLI(["chat", "status"])["result"] as? [String: Any])?["activePage"] as? [String: Any])?["id"] as? String)
        let firstJupiterTurn = try XCTUnwrap(historyMessages().last?["turnID"] as? String)

        // Send in parallel: the bubble floats right of the chat with a spinner, and the chat keeps
        // a placeholder where its page will return: above the current page.
        try Data("Hold the salad bubble.\n".utf8).write(to: URL(fileURLWithPath: executable + ".hold-parallel-salad-lunch"))
        sendInParallelFromChat(Self.parallelSaladPrompt, captureComposer: true)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".parallel-salad-lunch-active") }, timeout: 30),
                      "The parallel turn is held.")
        let salad = parallelBubbleButton(Self.parallelSaladPrompt)
        XCTAssertTrue(salad.waitToExist(timeout: 10), "The bubble shows its question.")
        let saladClose = closeOf(Self.parallelSaladPrompt)
        XCTAssertGreaterThanOrEqual(salad.frame.minX, element("chat-sidebar").frame.maxX, "The bubble floats out of the chat's right edge.")
        XCTAssertTrue(element("parallel-chat-bubble-progress").waitToExist(timeout: 5), "The bubble shows a spinner while it answers.")
        XCTAssertEqual(salad.value as? String, "Answering")
        XCTAssertFalse(saladClose.isEnabled, "A bubble that is still answering can't close.")
        XCTAssertEqual(composer.value as? String ?? "", "", "The question leaves the composer.")
        let listed = try XCTUnwrap(parallelBubbles().first)
        XCTAssertEqual(listed["prompt"] as? String, Self.parallelSaladPrompt)
        XCTAssertEqual(listed["isRunning"] as? Bool, true)
        XCTAssertEqual(listed["anchorTurnID"] as? String, firstJupiterTurn, "The bubble returns relative to the chat's last turn when it was sent.")
        let saladID = try XCTUnwrap(listed["id"] as? String)
        let placeholder = parallelPlaceholder(Self.parallelSaladPrompt)
        XCTAssertTrue(placeholder.waitToExist(timeout: 10), "The chat shows the bubble's placeholder.")
        XCTAssertLessThan(placeholder.frame.maxY, try XCTUnwrap(chatMessages(Self.parallelJupiterPrompt).first).frame.minY,
                          "The placeholder sits above the chat's current page, where the bubble's page will return.")
        bringIntoTranscriptViewport(placeholder, scrollView: scrollView)
        XCTAssertTrue(scrollView.frame.contains(placeholder.frame), "The placeholder is visible after scrolling to it.")
        attachScreenshot(named: "parallel-bubble-1-running-with-placeholder")
        attachRegionScreenshot([salad, element("parallel-chat-bubble-progress")], named: "parallel-bubble-1-running-close-up")
        attachElementScreenshot(placeholder, named: "parallel-bubble-1-placeholder-element")
        attachRegionScreenshot([placeholder, try XCTUnwrap(chatMessages(Self.parallelJupiterPrompt).first)], named: "parallel-bubble-1-placeholder-close-up")

        // The chat answers at once while the bubble is still running, and the placeholder stays
        // above the page the chat goes on with.
        sendInChat(Self.parallelJupiterPrompt, expecting: [
            Self.parallelJupiterPrompt, Self.parallelJupiterAnswer, Self.parallelJupiterPrompt, Self.parallelJupiterAnswer,
        ])
        XCTAssertTrue(element("parallel-chat-bubble-progress").exists, "The bubble still answers.")
        XCTAssertTrue(waitUntil({ chatMessages(Self.parallelJupiterAnswer).count == 2 }, timeout: 10))
        XCTAssertTrue(scrollTranscriptUntilExists(placeholder))
        XCTAssertLessThan(placeholder.frame.maxY, try XCTUnwrap(chatMessages(Self.parallelJupiterPrompt).first).frame.minY,
                          "The placeholder stays above the page's first turn.")

        touch(executable + ".parallel-salad-lunch-release")
        XCTAssertTrue(element("parallel-chat-bubble-done").waitToExist(timeout: 30), "The answered bubble shows it is done.")
        XCTAssertTrue(waitUntil({ saladClose.isEnabled && salad.value as? String == "Answered" }, timeout: 10))
        let fresh = try XCTUnwrap(fixtureTurns(endingWith: Self.parallelSaladPrompt).last)
        let jupiterSession = try XCTUnwrap(fixtureTurns(endingWith: Self.parallelJupiterPrompt).last?["sessionID"] as? String)
        XCTAssertEqual(fresh["resumed"] as? Bool, false, "The bubble starts a provider session of its own.")
        XCTAssertNotEqual(fresh["sessionID"] as? String, jupiterSession)

        // The answered bubble opens into its own conversation; a follow-up stays on its page.
        salad.click()
        let panel = element("parallel-chat-panel")
        XCTAssertTrue(panel.waitToExist(timeout: 10), "The bubble opens into a larger view.")
        func panelShows(_ text: String) -> Bool {
            panel.descendants(matching: .group).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        XCTAssertTrue(waitUntil({ panelShows(Self.parallelSaladAnswer) }, timeout: 15), "The larger view shows the bubble's answer.")
        let panelComposer = parallelPanelElement("message-composer")
        XCTAssertTrue(panelComposer.waitToExist(timeout: 10))
        XCTAssertFalse(parallelPanelElement("composer-send-in-parallel-button").exists, "A bubble doesn't open bubbles of its own.")
        let back = parallelPanelElement("back-to-board-button")
        XCTAssertTrue(waitUntil({ back.isHittable && self.parallelPanelElement("task-view-title").exists }, timeout: 10))
        XCTAssertEqual(back.label, "Back to the bubble")
        for identifier in ["parallel-chat-panel-title", "parallel-chat-panel-collapse", "parallel-chat-panel-close"] {
            XCTAssertFalse(parallelPanelElement(identifier).exists, "The expanded page uses only its page header.")
        }
        attachAppWindowScreenshot(named: "parallel-bubble-page-navigation")
        attachElementScreenshot(panel, named: "parallel-bubble-page-navigation-detail")
        back.click()
        XCTAssertTrue(waitUntil({ !panel.exists && salad.isHittable && placeholder.exists }, timeout: 10),
                      "Back returns to the bubble and keeps its placeholder.")
        salad.click()
        XCTAssertTrue(waitUntil({ panelComposer.isHittable }, timeout: 10))
        panelComposer.click()
        panelComposer.typeText(Self.parallelDressingPrompt)
        let panelSend = parallelPanelElement("send-message-button")
        XCTAssertTrue(waitUntil({ panelSend.isHittable }, timeout: 10), "The expanded page's Send button fits on the display.")
        panelSend.click()
        XCTAssertTrue(waitUntil({
            self.parallelHistoryTexts(saladID) == [Self.parallelSaladPrompt, Self.parallelSaladAnswer, Self.parallelDressingPrompt, Self.parallelDressingAnswer]
        }, timeout: 30), "The follow-up continues the bubble's conversation.")
        XCTAssertTrue(waitUntil({ panelShows(Self.parallelDressingAnswer) }, timeout: 15), "The larger view shows the follow-up's answer.")
        let followUp = try XCTUnwrap(fixtureTurns(endingWith: Self.parallelDressingPrompt).last)
        XCTAssertEqual(followUp["resumed"] as? Bool, true)
        XCTAssertEqual(followUp["sessionID"] as? String, fresh["sessionID"] as? String)
        attachScreenshot(named: "parallel-bubble-3-follow-up")
        XCTAssertTrue(waitUntil({ back.isHittable }, timeout: 10))
        back.click()
        XCTAssertTrue(waitUntil({
            !panel.exists && saladClose.isHittable && saladClose.isEnabled
        }, timeout: 15), "The answered page returns to a bubble with an available close action.")
        XCTAssertTrue(waitForStableFrame(saladClose))

        // Closing the bubble returns the page above the page the chat kept adding to.
        saladClose.click()
        XCTAssertTrue(waitUntil({ !salad.exists && !placeholder.exists && !panel.exists }, timeout: 20),
                      "The bubble, its larger view and its placeholder go away.")
        let saladTexts = [Self.parallelSaladPrompt, Self.parallelSaladAnswer, Self.parallelDressingPrompt, Self.parallelDressingAnswer]
        XCTAssertTrue(waitUntil({
            self.parallelHistoryTexts(chatID) == saladTexts + [Self.parallelJupiterPrompt, Self.parallelJupiterAnswer, Self.parallelJupiterPrompt, Self.parallelJupiterAnswer]
        }, timeout: 20), "The bubble's page returns above the chat's page: \(parallelHistoryTexts(chatID))")
        XCTAssertTrue(parallelBubbles().isEmpty)
        let pages = parallelChatPages()
        let saladPage = try XCTUnwrap(pages.first { $0["title"] as? String == "Salad lunch" })
        let saladPageID = try XCTUnwrap(saladPage["id"] as? String)
        XCTAssertEqual(saladPage["chatID"] as? String, "default")
        XCTAssertEqual(pages.compactMap { $0["id"] as? String }, [jupiterPageID, saladPageID])

        // The page labels list it above the chat's page, and jumping to it shows its window.
        let handle = element("chat-page-anchors-handle")
        XCTAssertTrue(handle.waitToExist(timeout: 5))
        handle.hover()
        XCTAssertTrue(waitUntil({ handle.value as? String == "open" }, timeout: 5))
        // Keep the labels open while clicking the bubble stack. Hover-only labels change the
        // sidebar width as the pointer leaves them, moving the stack during a synthesized click.
        handle.click()
        XCTAssertTrue(waitUntil({ handle.value as? String == "locked" }, timeout: 5))
        let saladLabel = element("chat-page-anchor-\(saladPageID)")
        let jupiterLabel = element("chat-page-anchor-\(jupiterPageID)")
        XCTAssertTrue(saladLabel.waitToExist(timeout: 10), "The page labels show the returned page.")
        XCTAssertTrue(jupiterLabel.waitToExist(timeout: 5))
        XCTAssertLessThan(saladLabel.frame.midY, jupiterLabel.frame.midY, "The returned page's label sits above the chat's page.")
        XCTAssertNotEqual(saladLabel.value as? String, "current", "The chat opens on its newest page.")
        attachScreenshot(named: "parallel-bubble-4-returned-with-labels")
        attachRegionScreenshot([saladLabel, jupiterLabel], named: "parallel-bubble-4-labels-close-up")
        attachElementScreenshot(saladLabel, named: "parallel-bubble-4-returned-label-element")
        saladLabel.click()
        XCTAssertTrue(waitUntil({
            guard let saladPrompt = chatMessages(Self.parallelSaladPrompt).first else { return false }
            return saladLabel.value as? String == "current" && self.chatPageSeparatorIsVisible("Salad lunch")
                && scrollView.frame.intersects(saladPrompt.frame)
        }, timeout: 15), "Jumping to the returned page shows it from its first message.")
        XCTAssertTrue(waitUntil({
            guard let prompt = chatMessages(Self.parallelSaladPrompt).first,
                  let reply = chatMessages(Self.parallelSaladAnswer).first else { return false }
            return prompt.frame.maxY < reply.frame.minY && scrollView.frame.intersects(reply.frame)
        }, timeout: 10), "The returned page displays its question and answer in order.")
        attachScreenshot(named: "parallel-bubble-4-jumped-to-returned-page")

        // A bubble whose page the chat goes on with and then leaves returns above that page; a
        // bubble sent at the end of a page the chat then leaves returns between the two pages.
        if !jupiterLabel.isHittable { handle.hover() }
        XCTAssertTrue(waitUntil({ jupiterLabel.isHittable }, timeout: 5))
        jupiterLabel.click()
        XCTAssertTrue(waitUntil({ jupiterLabel.value as? String == "current" }, timeout: 10))
        sendInParallelFromChat(Self.parallelSoupPrompt)
        let soup = parallelBubbleButton(Self.parallelSoupPrompt)
        XCTAssertTrue(soup.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.parallelBubbles().first?["isRunning"] as? Bool == false }, timeout: 30), "The soup bubble answers.")
        let jupiterTexts = Array(repeating: [Self.parallelJupiterPrompt, Self.parallelJupiterAnswer], count: 3).flatMap { $0 }
        sendInChat(Self.parallelJupiterPrompt, expecting: saladTexts + jupiterTexts)
        sendInParallelFromChat(Self.parallelTacoPrompt)
        let taco = parallelBubbleButton(Self.parallelTacoPrompt)
        XCTAssertTrue(taco.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ self.parallelBubbles().count == 2 && self.parallelBubbles().allSatisfy { $0["isRunning"] as? Bool == false } }, timeout: 30),
                      "The taco bubble answers.")
        let newPage = chatSidebarElement("new-chat-page-button")
        XCTAssertTrue(newPage.waitToExist(timeout: 10))
        newPage.click()
        sendInChat(Self.parallelPastaPrompt, expecting: saladTexts + jupiterTexts + [Self.parallelPastaPrompt, Self.parallelPastaAnswer])
        let soupPlaceholder = parallelPlaceholder(Self.parallelSoupPrompt)
        let tacoPlaceholder = parallelPlaceholder(Self.parallelTacoPrompt)
        // At the bottom, the taco placeholder sits between the page it was sent at the end of
        // and the new page.
        XCTAssertTrue(scrollTranscriptUntilExists(tacoPlaceholder))
        XCTAssertTrue(waitUntil({
            guard tacoPlaceholder.exists, let lastJupiterAnswer = chatMessages(Self.parallelJupiterAnswer).last,
                  let pasta = chatMessages(Self.parallelPastaPrompt).first else { return false }
            return tacoPlaceholder.frame.minY > lastJupiterAnswer.frame.maxY && tacoPlaceholder.frame.maxY < pasta.frame.minY
        }, timeout: 15), "The taco placeholder sits between the two pages.")
        attachRegionScreenshot([tacoPlaceholder, try XCTUnwrap(chatMessages(Self.parallelPastaPrompt).first)], named: "parallel-bubble-5-taco-placeholder-close-up")
        // Jumping to the page the chat went on with shows the soup placeholder above it.
        if handle.waitToExist(timeout: 5) { handle.hover() }
        XCTAssertTrue(jupiterLabel.waitToExist(timeout: 10))
        jupiterLabel.click()
        XCTAssertTrue(waitUntil({
            guard soupPlaceholder.exists, let firstJupiter = chatMessages(Self.parallelJupiterPrompt).first else { return false }
            return jupiterLabel.value as? String == "current" && soupPlaceholder.frame.maxY < firstJupiter.frame.minY
        }, timeout: 15), "The soup placeholder sits above the page the chat went on with.")
        attachScreenshot(named: "parallel-bubble-5-soup-placeholder-above-page")
        for prompt in [Self.parallelSoupPrompt, Self.parallelTacoPrompt] {
            let close = closeOf(prompt)
            XCTAssertTrue(waitUntil({ close.isEnabled && close.isHittable }, timeout: 10))
            XCTAssertTrue(waitForStableFrame(close))
            close.click()
            XCTAssertTrue(waitUntil({ !self.parallelBubbleButton(prompt).exists }, timeout: 20), "Closing \(prompt) returns its page.")
        }
        XCTAssertTrue(waitUntil({ self.parallelBubbles().isEmpty && !soupPlaceholder.exists && !tacoPlaceholder.exists }, timeout: 20))
        XCTAssertTrue(waitUntil({
            self.parallelHistoryTexts(chatID) == saladTexts + [Self.parallelSoupPrompt, Self.parallelSoupAnswer] + jupiterTexts
                + [Self.parallelTacoPrompt, Self.parallelTacoAnswer, Self.parallelPastaPrompt, Self.parallelPastaAnswer]
        }, timeout: 20), "Both pages return to their spots: \(parallelHistoryTexts(chatID))")
        let finalPages = parallelChatPages()
        let titles = finalPages.compactMap { $0["title"] as? String }
        XCTAssertEqual(titles.count, 5)
        XCTAssertEqual(titles[0], "Pasta dinner")
        XCTAssertEqual(titles[1], "Taco breakfast")
        XCTAssertEqual(finalPages[2]["id"] as? String, jupiterPageID)
        XCTAssertEqual(Array(titles[3...]), ["Soup supper", "Salad lunch"])
        let tacoPageID = try XCTUnwrap(finalPages[1]["id"] as? String)
        openReturnedParallelPage(tacoPageID, title: "Taco breakfast")
        attachScreenshot(named: "parallel-bubble-6-returned-in-order")
    }

    // case-contract: test_parallel_chat_bubble_close_refused_while_generating | A parallel bubble cannot close while it is still answering: chat bubble close is invalid_transition, and in the app the bubble's close button is disabled while its spinner shows, so the bubble, its placeholder and its unfinished page stay where they are, and the chat lists no new page; once the answer arrives the same close succeeds. An unknown bubble is not_found, and a parallel send without a message is invalid_argument and opens no bubble. The close check reads Playhouse's own turn reservation, so one representative provider (Claude) covers the case.
    func test_parallel_chat_bubble_close_refused_while_generating() throws {
        let environment = try installClaudeFixture(named: "claude-fixture-ui-parallel-refused")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)

        // An empty composer offers no parallel send, and the CLI refuses an empty one.
        let parallel = chatSidebarElement("composer-send-in-parallel-button")
        XCTAssertTrue(parallel.waitToExist(timeout: 10))
        XCTAssertFalse(parallel.isEnabled, "Send in parallel needs a message.")
        let empty = try runCLI(["chat", "bubble", "send", "--message", "   "], expectedStatus: 2)
        XCTAssertEqual((empty["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let unknown = try runCLI(["chat", "bubble", "close", UUID().uuidString], expectedStatus: 3)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, "not_found")
        XCTAssertTrue(parallelBubbles().isEmpty)
        XCTAssertFalse(element("parallel-chat-bubble").exists, "No bubble opens.")

        try Data("Hold the salad bubble.\n".utf8).write(to: URL(fileURLWithPath: executable + ".hold-parallel-salad-lunch"))
        sendInParallelFromChat(Self.parallelSaladPrompt)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".parallel-salad-lunch-active") }, timeout: 30))
        let salad = parallelBubbleButton(Self.parallelSaladPrompt)
        XCTAssertTrue(salad.waitToExist(timeout: 10))
        // The real bubble, with its close button, replaces the one shown while the send starts.
        XCTAssertTrue(waitUntil({ self.parallelBubbleClose(Self.parallelSaladPrompt).exists }, timeout: 15))
        let close = parallelBubbleClose(Self.parallelSaladPrompt)
        XCTAssertTrue(element("parallel-chat-bubble-progress").exists)
        XCTAssertEqual(salad.value as? String, "Answering")
        XCTAssertFalse(close.isEnabled, "The close button is disabled while the bubble answers.")
        XCTAssertFalse(salad.isEnabled, "A bubble that is still answering doesn't open yet.")
        close.click()
        let bubbleID = try XCTUnwrap(parallelBubbles().first?["id"] as? String)
        let refused = try runCLI(["chat", "bubble", "close", bubbleID], expectedStatus: 1)
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        XCTAssertTrue(salad.exists, "The bubble stays.")
        XCTAssertTrue(parallelPlaceholder(Self.parallelSaladPrompt).exists, "Its placeholder stays.")
        XCTAssertEqual(parallelBubbles().compactMap { $0["id"] as? String }, [bubbleID])
        XCTAssertTrue(parallelChatPages().isEmpty, "The chat lists no new page.")
        attachScreenshot(named: "parallel-bubble-close-disabled-while-answering")
        attachRegionScreenshot([salad, close], named: "parallel-bubble-close-disabled-close-up")

        touch(executable + ".parallel-salad-lunch-release")
        XCTAssertTrue(waitUntil({ close.isEnabled }, timeout: 30), "The close button turns on once the bubble answers.")
        close.click()
        XCTAssertTrue(waitUntil({ !salad.exists && self.parallelBubbles().isEmpty }, timeout: 20), "The answered bubble closes.")
        XCTAssertTrue(waitUntil({ self.parallelHistoryTexts(chatID) == [Self.parallelSaladPrompt, Self.parallelSaladAnswer] }, timeout: 20))
        let returnedPages = parallelChatPages()
        XCTAssertEqual(returnedPages.count, 1)
        let returnedPageID = try XCTUnwrap(returnedPages.first?["id"] as? String)
        XCTAssertEqual(restartChatPageTexts(returnedPageID, environment: environment), [Self.parallelSaladPrompt, Self.parallelSaladAnswer])
    }

    // case-contract: test_parallel_chat_bubbles_persist_across_restart | Open parallel bubbles survive a restart: after the bridge daemon is killed while one bubble is still answering and another has answered (in the app, after a relaunch), chat bubble list still reports both with their questions and the chat turn each returns after, and the app shows both bubbles again with their placeholders. The new daemon follows the bubble turn that was running and files it on the bubble's own page, named by its close-turn, never on a page of the chat, which keeps its own messages. Both bubbles then close into place above the chat's current page, oldest first, with all their messages. The bubble is a standalone chat conversation of its own, so it recovers through the chat's provider-neutral restart path; one representative provider (Claude) covers the case.
    func test_parallel_chat_bubbles_persist_across_restart() throws {
        let (executable, environment, chatID) = try launchRestartFixtureChat()
        let mainQuestion = "Name a moon of Mars."
        _ = sendFiledRestartChatTurn(executable, mainQuestion, environment: environment)
        let mainPageID = try XCTUnwrap((restartChatStatus(environment)?["activePage"] as? [String: Any])?["id"] as? String)
        let mainTexts = [mainQuestion, "Before restart.", "After restart."]

        // One bubble answers before the restart.
        let hikeQuestion = "Plan a weekend hike."
        try? FileManager.default.removeItem(atPath: executable + ".reattach-ready")
        sendInParallelFromChat(hikeQuestion)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20), "The first bubble's turn runs.")
        closeHeldChatTurn(executable, newTitle: "Weekend hike")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({
            let bubbles = self.parallelBubbles(environment: environment)
            return bubbles.count == 1 && bubbles[0]["isRunning"] as? Bool == false
                && self.agentManifest(kind: "claude", service: environment) == nil
        }, timeout: 30), "The first bubble answers.")

        // The other is still answering when the app closes and its daemon dies.
        let packingQuestion = "Write a packing list for the hike."
        try? FileManager.default.removeItem(atPath: executable + ".reattach-ready")
        sendInParallelFromChat(packingQuestion)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20),
                      "The second bubble's turn runs before the daemon dies.")
        XCTAssertTrue(parallelBubbleButton(packingQuestion).waitToExist(timeout: 10))
        attachScreenshot(named: "parallel-bubbles-restart-1-before")
        XCTAssertTrue(terminateAppAndWait(app))
        try killDaemon(environment: environment)

        launchApp(defaultParent: nil, environmentOverrides: environment)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let bubbles = parallelBubbles(environment: environment)
        XCTAssertEqual(bubbles.compactMap { $0["prompt"] as? String }, [hikeQuestion, packingQuestion])
        XCTAssertTrue(bubbles.allSatisfy { $0["anchorTurnID"] as? String != nil })
        XCTAssertTrue(parallelBubbleButton(hikeQuestion).waitToExist(timeout: 15), "The answered bubble is back after the relaunch.")
        XCTAssertTrue(parallelBubbleButton(packingQuestion).waitToExist(timeout: 15), "The running bubble is back after the relaunch.")
        XCTAssertTrue(waitUntil({ self.parallelBubbleButton(hikeQuestion).value as? String == "Answered" }, timeout: 10), "The answered bubble shows it is done.")
        XCTAssertEqual(parallelBubbleButton(packingQuestion).value as? String, "Answering", "The followed bubble still shows its spinner.")
        XCTAssertTrue(parallelPlaceholder(hikeQuestion).waitToExist(timeout: 10))
        XCTAssertTrue(parallelPlaceholder(packingQuestion).exists)
        let restoredPlaceholder = parallelPlaceholder(hikeQuestion)
        let transcript = chatSidebarElement("conversation-scroll-view")
        bringIntoTranscriptViewport(restoredPlaceholder, scrollView: transcript)
        XCTAssertTrue(transcript.frame.contains(restoredPlaceholder.frame))
        XCTAssertTrue(transcript.frame.contains(parallelPlaceholder(packingQuestion).frame))
        attachScreenshot(named: "parallel-bubbles-restart-2-restored")

        let packingID = try XCTUnwrap(bubbles[1]["id"] as? String)
        closeHeldChatTurn(executable, newTitle: "Packing list")
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({ self.parallelHistoryTexts(packingID, environment: environment).contains("After restart.") }, timeout: 40),
                      "The followed bubble turn finishes.")
        XCTAssertTrue(waitUntil({ self.parallelBubbles(environment: environment).last?["isRunning"] as? Bool == false }, timeout: 40))
        XCTAssertEqual(parallelChatPages(environment: environment).compactMap { $0["id"] as? String }, [mainPageID],
                       "The followed bubble turn is never filed on a page of the chat.")
        XCTAssertEqual(restartChatPageTexts(mainPageID, environment: environment), mainTexts)

        for question in [hikeQuestion, packingQuestion] {
            let close = parallelBubbleClose(question)
            XCTAssertTrue(waitUntil({ close.isEnabled }, timeout: 15))
            close.click()
            XCTAssertTrue(waitUntil({ !self.parallelBubbleButton(question).exists }, timeout: 20))
        }
        XCTAssertTrue(waitUntil({
            self.parallelHistoryTexts(chatID, environment: environment) == [
                hikeQuestion, "Before restart.", "After restart.",
                packingQuestion, "Before restart.", "After restart.",
            ] + mainTexts
        }, timeout: 20), "Both bubbles return above the chat's page, oldest first.")
        let pages = parallelChatPages(environment: environment)
        XCTAssertEqual(pages.compactMap { $0["title"] as? String }.dropFirst(), ["Packing list", "Weekend hike"])
        let packingPageID = try XCTUnwrap(pages.first { $0["title"] as? String == "Packing list" }?["id"] as? String)
        XCTAssertEqual(restartChatPageTexts(packingPageID, environment: environment), [packingQuestion, "Before restart.", "After restart."])
        XCTAssertTrue(parallelBubbles(environment: environment).isEmpty)
        openReturnedParallelPage(packingPageID, title: "Packing list")
        attachScreenshot(named: "parallel-bubbles-restart-3-returned")
    }
}

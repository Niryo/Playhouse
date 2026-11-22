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
    // case-contract: test_standalone_chat_page_sessions_isolate_context | Each standalone chat page is its own provider session: the first turn of a page starts a fresh session carrying the system prompt, which explains the page metadata header and tells the agent to run chat page read only for a page the message continues, plus a Playhouse page metadata header, never a User line, that names the current page by title and ID with a shortened excerpt of its latest exchange and lists recent pages newest first by title and ID only. Later turns on that page resume it without repeating the header, and a different page never shares it, so an earlier page's turns never reach a later page. An annotation that quotes an earlier page carries that whole page into the current turn, marked as a Playhouse page. A page whose latest answer is long sends only the start of that answer, and the agent loads the whole page itself with the real chat page read command. Rotating sessions still leaves every page's messages visible in the transcript.
    func test_standalone_chat_page_sessions_isolate_context() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-page-sessions")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)

        func waitForPage(_ title: String) throws -> [String: Any] {
            var active: [String: Any] = [:]
            let settled = waitUntil({
                guard let response = try? self.runCLI(["chat", "status"]),
                      let status = response["result"] as? [String: Any],
                      let page = status["activePage"] as? [String: Any],
                      (status["missedPreviousPageSignal"] as? Bool) == false,
                      page["title"] as? String == title else { return false }
                active = page
                return true
            }, timeout: 30)
            XCTAssertTrue(settled, "The chat never settled on page \(title).")
            return active
        }

        func sendFromSidebar(_ prompt: String) {
            let composer = element("message-composer")
            XCTAssertTrue(composer.waitToExist(timeout: 10))
            let receivedBefore = fixtureTurnCount(executable, containing: prompt)
            composer.click()
            composer.typeText(prompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                self.fixtureTurnCount(executable, containing: prompt) > receivedBefore && self.noTurnIsRunning()
            }, timeout: 30), "The turn should finish.")
        }

        func answerTurns() throws -> [[String: Any]] {
            let data = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
            let history = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let turns = try XCTUnwrap(history["turns"] as? [[String: Any]])
            return turns.filter { !(($0["userText"] as? String) ?? "").hasPrefix("Classify the latest user message") }
        }

        func turn(endingWith message: String) throws -> [String: Any] {
            let match = try answerTurns().last { (($0["userText"] as? String) ?? "").hasSuffix(message) }
            return try XCTUnwrap(match, "The fixture never received a turn ending with \(message).")
        }

        sendFromSidebar("Tell me about volcanoes")
        let volcanoes = try waitForPage("Volcanoes")
        sendFromSidebar("Tell me about Saturn's rings")
        let saturn = try waitForPage("Saturn Rings")
        sendFromSidebar("One more thought about Saturn")
        _ = try waitForPage("Saturn Rings")

        let first = try turn(endingWith: "Tell me about volcanoes")
        let second = try turn(endingWith: "Tell me about Saturn's rings")
        let third = try turn(endingWith: "One more thought about Saturn")
        // The turn that opens a page still answers in the page it was sent into; only once the
        // classifier moves it does the next turn get that new page's own session.
        XCTAssertEqual(first["sessionID"] as? String, second["sessionID"] as? String, "One page answers in one session.")
        XCTAssertNotEqual(
            third["sessionID"] as? String, first["sessionID"] as? String,
            "A different page must never share another page's provider session."
        )
        for pageTurn in [first, third] {
            XCTAssertEqual(pageTurn["resumed"] as? Bool, false, "A page's first turn starts that page's own session.")
            let arguments = try XCTUnwrap(pageTurn["arguments"] as? [String])
            let promptIndex = try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt"))
            XCTAssertTrue(
                arguments[promptIndex + 1].contains("chat page close-turn"),
                "Every page session must carry the standalone chat system prompt."
            )
        }
        XCTAssertEqual(second["resumed"] as? Bool, true, "A turn sent into an existing page resumes its session.")
        let volcanoesID = try XCTUnwrap(volcanoes["id"] as? String)
        let saturnID = try XCTUnwrap(saturn["id"] as? String)
        let thirdArguments = try XCTUnwrap(third["arguments"] as? [String])
        let thirdInstructions = thirdArguments[try XCTUnwrap(thirdArguments.firstIndex(of: "--append-system-prompt")) + 1]
        XCTAssertTrue(thirdInstructions.contains("Playhouse page metadata block"), "The chat instructions explain the page metadata header.")
        XCTAssertTrue(
            thirdInstructions.contains("chat page read <page-id> to load that page before answering"),
            "The chat instructions tell the agent to load a continued page itself."
        )
        let thirdText = try XCTUnwrap(third["userText"] as? String)
        XCTAssertTrue(thirdText.contains("User: Tell me about Saturn's rings"), "A fresh page session gets its own page's latest exchange as an excerpt.")
        XCTAssertTrue(thirdText.contains("Playhouse chat page metadata, not part of the user's message."))
        XCTAssertTrue(thirdText.contains("Current page: \"Saturn Rings\" (id: \(saturnID), "), "The header names the current page by title and ID.")
        XCTAssertTrue(
            thirdText.contains("Recent pages, newest first:\n- \"Volcanoes\" (id: \(volcanoesID), "),
            "The header lists earlier pages by title and ID."
        )
        XCTAssertFalse(thirdText.contains("[Page:"), "A page title is never written as a user line.")
        XCTAssertFalse(
            thirdText.contains("Tell me about volcanoes"),
            "An earlier page's turns are never sent as context for a later page, only its title and ID."
        )

        sendFromSidebar("Another thought about Mars")
        _ = try waitForPage("Saturn Rings")
        let fourth = try turn(endingWith: "Another thought about Mars")
        XCTAssertEqual(fourth["sessionID"] as? String, third["sessionID"] as? String, "The same page keeps one session.")
        XCTAssertEqual(fourth["resumed"] as? Bool, true, "A continuing turn resumes the page's session.")
        XCTAssertFalse(
            try XCTUnwrap(fourth["userText"] as? String).contains("<playhouse-handoff-context>"),
            "A resumed page session must not repeat its page context."
        )

        // Commenting on a message from an earlier page must carry that page into this turn.
        // Driven through the visible select -> Add comment -> send flow, not the CLI flag, so
        // the composer's own annotation-to-page mapping is what is exercised.
        let archived = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", volcanoesID])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertFalse(archived.isEmpty, "The earlier page should still hold its own turns.")
        let historyMessages = try XCTUnwrap(
            (try runCLI(["conversation", "history", chatID])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        let volcanoMessage = try XCTUnwrap(
            historyMessages.first { ($0["text"] as? String) == "Tell me about volcanoes" },
            "The earlier page's message should still be in the visible transcript."
        )
        let volcanoMessageID = try XCTUnwrap(volcanoMessage["id"] as? String)
        let volcanoView = element("user-message-\(volcanoMessageID)")
        XCTAssertTrue(scrollTranscriptUntilExists(volcanoView), "An earlier page's message stays visible after rotation.")
        XCTAssertTrue(revealInConversation(volcanoView), "The earlier page's message should scroll fully into view before it is clicked.")
        volcanoView.click()
        volcanoView.typeKey("a", modifierFlags: .command)
        // The selection pill's Comment opens the comment popover; its arrow adds a comment on a user message.
        addCommentFromSelection("What did we say before?")
        XCTAssertTrue(waitUntil({ element("send-message-button").isEnabled }, timeout: 5), "A comment alone should be sendable.")
        XCTAssertTrue(waitUntil({
            self.accessibleLabelOrValue(of: self.element("pending-comment-count")).contains("1 comment")
        }, timeout: 5), "The arrow adds exactly one comment on a user message.")
        let annotatedBefore = fixtureTurnCount(executable, containing: "What did we say before?")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: "What did we say before?") > annotatedBefore && self.noTurnIsRunning()
        }, timeout: 30), "The annotated turn should finish.")
        _ = try waitForPage("Saturn Rings")
        let annotated = try XCTUnwrap(
            try answerTurns().last { (($0["userText"] as? String) ?? "").contains("What did we say before?") },
            "The annotated turn never reached the provider."
        )
        let annotatedText = try XCTUnwrap(annotated["userText"] as? String)
        XCTAssertTrue(annotatedText.contains("User: Tell me about volcanoes"), "A page quoted by a comment travels whole with the turn that quotes it.")
        XCTAssertTrue(
            annotatedText.contains("Playhouse page \"Volcanoes\" (id: \(volcanoesID), "),
            "An attached page is marked as a Playhouse page, not as a user line."
        )
        XCTAssertFalse(annotatedText.contains("[Page:"))

        // A page whose answer is long: the next turn, in that page's fresh session, gets only a
        // shortened excerpt of the latest exchange, and loads the whole page with chat page read.
        sendFromSidebar("Open a lava page long-answer-page:Lava-Flows")
        let lavaID = try XCTUnwrap(try waitForPage("Lava Flows")["id"] as? String)
        let recall = "recall-earlier-pages page-id:\(lavaID)"
        sendFromSidebar(recall)
        _ = try waitForPage("Lava Flows")
        let recalled = try turn(endingWith: recall)
        XCTAssertEqual(recalled["resumed"] as? Bool, false, "The new page's first turn starts that page's own session.")
        let header = try XCTUnwrap(recalled["userText"] as? String)
        XCTAssertTrue(header.contains("Current page: \"Lava Flows\" (id: \(lavaID), "))
        let saturnLine = try XCTUnwrap(header.range(of: "- \"Saturn Rings\" (id: \(saturnID), "), "Recent pages are listed.")
        let volcanoesLine = try XCTUnwrap(header.range(of: "- \"Volcanoes\" (id: \(volcanoesID), "))
        XCTAssertLessThan(saturnLine.lowerBound, volcanoesLine.lowerBound, "Recent pages are listed newest first.")
        XCTAssertTrue(header.contains("Claude: Lava Flows full answer: lava detail"), "The excerpt keeps the start of the latest answer.")
        XCTAssertTrue(header.contains(" […]"), "A long answer is shortened in the excerpt.")
        XCTAssertFalse(header.contains("END-OF-LONG-ANSWER"), "The whole answer is not sent until the agent reads the page.")
        XCTAssertFalse(header.contains("Lava Flows opening note."), "Only the latest exchange is excerpted.")
        XCTAssertFalse(header.contains("One more thought about Saturn"), "Another page's turns never travel with the header.")
        XCTAssertLessThan(header.count - recall.count, 3_500, "The header stays small however long the page is.")
        let reads = ((recalled["reportCommands"] as? [[String: Any]]) ?? []).filter {
            (($0["command"] as? String) ?? "").contains(" chat page read ")
        }
        XCTAssertEqual(reads.count, 1, "The agent loads the continued page itself.")
        let readOutput = try XCTUnwrap(reads.first?["output"] as? String)
        let loaded = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(readOutput.utf8)) as? [String: Any])?["result"] as? [String: Any]
        )
        XCTAssertEqual((loaded["page"] as? [String: Any])?["id"] as? String, lavaID)
        XCTAssertTrue(
            ((loaded["messages"] as? [[String: Any]]) ?? []).contains { (($0["text"] as? String) ?? "").hasSuffix("END-OF-LONG-ANSWER") },
            "chat page read returns the whole page, long answer included."
        )

        // The transcript renders a window that starts at the latest turn, so earlier pages are
        // revealed before checking that rotating sessions kept every one of them.
        XCTAssertTrue(revealWholeTranscript(), "The whole chat transcript should load.")
        // Earlier pages render only near the viewport, so each check scans the transcript.
        XCTAssertTrue(transcriptScan { self.chatPageSeparatorIsVisible("Volcanoes") }, "Rotating sessions must not hide earlier pages.")
        XCTAssertTrue(transcriptScan { self.chatPageSeparatorIsVisible("Saturn Rings") })
        XCTAssertTrue(transcriptScan { self.chatPageSeparatorIsVisible("Lava Flows") })
        XCTAssertTrue(
            transcriptScan { self.element("chat-sidebar").groups["Tell me about volcanoes"].exists },
            "Earlier pages stay visible in the chat transcript."
        )
        attachScreenshot(named: "Standalone chat pages keep separate sessions")
    }
    // case-contract: test_standalone_chat_answer_stays_final_around_close_turn | A standalone chat reports no task outcome, so it ends every turn with Playhouse's own chat page close-turn signal. When Claude runs that signal after its answer and before its closing line, the answer and closing line form one final answer, not commentary, in the streamed final answer, fresh CLI/XPC history, and the visible transcript, so the response is never left buried inside the collapsed Worked for disclosure; text written before an ordinary tool earlier in the same turn still stays commentary there, and the close-turn command really runs and succeeds. The chat instructions ask for close-turn before the final reply, which must end the turn, keep exactly one real close-turn per turn and no page bookkeeping in the answer, and carry no hidden escalation. A turn that runs close-turn first and answers after it shows exactly one final answer, filed onto the active page, with no nudge. When the turn ends on close-turn and Claude Code adds its own no-visible-output notice to the same turn, the notice streams once as a user-side message and stays in fresh history between the answer and what Claude writes after it, rendering as an automatic message from Claude Code rather than the user's bubble; that later text is a separate final message, so no bubble holds the answer twice, and the notice is never filed into a chat page. This classification is Claude-specific because Playhouse derives each message's phase from Claude's tool stream and only Claude Code adds such a notice inside a turn, while Codex reports the phase in its own protocol and never injects a hidden message into a turn.
    func test_standalone_chat_answer_stays_final_around_close_turn() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-close-turn")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        _ = try runCLI(["chat", "open"])

        let intent = "Let me check the newer release first."
        let answer = "Confirmed: 2.1.309 registers the new model and 2.1.308 does not."
        let closing = "Tell me if you want the upgrade command."
        let prompt = "Summarize the release notes."
        // Transcript messages are labeled groups.
        func visibleTexts(containing text: String) -> XCUIElementQuery {
            app.groups.matching(NSPredicate(format: "label CONTAINS %@", text))
        }

        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText(prompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: prompt) > 0 && self.noTurnIsRunning()
        }, timeout: 30), "The chat turn should finish.")
        XCTAssertTrue(waitUntil({
            self.element("codex-activity-disclosure").exists
                && self.element("codex-activity-disclosure").label.hasPrefix("Worked for")
        }, timeout: 20), "The settled chat turn should show its Worked for summary.")

        // Settling re-renders the transcript (commentary folds into Worked for), so the answer can briefly be mid-layout.
        XCTAssertTrue(visibleTexts(containing: answer).firstMatch.waitToExist(timeout: 10),
                      "The answer written before the close-turn signal must be the visible response, not collapsed commentary.")
        XCTAssertTrue(visibleTexts(containing: closing).firstMatch.waitToExist(timeout: 5),
                      "The closing line Claude adds after the signal belongs to the same answer.")
        XCTAssertEqual(visibleTexts(containing: intent).count, 0,
                       "Text written before an ordinary tool stays collapsed commentary.")
        attachScreenshot(named: "standalone-chat-answer-is-the-response")

        element("codex-activity-disclosure").click()
        let activityDetails = element("codex-activity-details")
        XCTAssertTrue(activityDetails.waitToExist(timeout: 5), "Worked for should expand.")
        // A progress bubble carries its text as the element's value, not its label, so it is
        // identified by the provider message it was built from.
        func progressBubbles(forMessageID messageID: String) -> XCUIElementQuery {
            activityDetails.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "codex-progress-message-\(messageID)")
            )
        }
        XCTAssertEqual(progressBubbles(forMessageID: "msg_chat_answer").count, 0,
                       "The answer must never be demoted into a Worked for progress entry.")
        let intentBubble = progressBubbles(forMessageID: "msg_chat_intent")
        XCTAssertTrue(intentBubble.count > 0,
                      "The text written before an ordinary tool belongs inside Worked for.")
        XCTAssertTrue((intentBubble.firstMatch.value as? String ?? "").contains(intent),
                      "The Worked for progress entry should carry the commentary Claude wrote before its tool call.")
        attachScreenshot(named: "standalone-chat-worked-for-holds-only-commentary")
        element("codex-activity-disclosure").click()

        let status = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        XCTAssertEqual(status["missedPreviousPageSignal"] as? Bool, false,
                       "A close-turn signal that really ran must satisfy the page signal instead of falling back to the classifier.")

        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        func fixtureTurns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter {
                !((($0["userText"] as? String) ?? "").hasPrefix("Classify the latest user message"))
            }
        }
        func nudgeCount() -> Int {
            fixtureTurns().filter { (($0["userText"] as? String) ?? "").contains("Playhouse internal outcome nudge:") }.count
        }
        func turnMessages(prompt: String) throws -> [(String, String?, String)] {
            let history = try XCTUnwrap(try runCLI(["conversation", "history", chatID])["result"] as? [String: Any])
            let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
            let turnID = try XCTUnwrap(messages.first { ($0["role"] as? String) == "user" && ($0["text"] as? String) == prompt }?["turnID"] as? String)
            return messages.filter { ($0["turnID"] as? String) == turnID }.map {
                (($0["role"] as? String) ?? "", $0["phase"] as? String, ($0["text"] as? String) ?? "")
            }
        }
        func send(_ prompt: String) {
            composer.click()
            composer.typeText(prompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                self.fixtureTurnCount(executable, containing: prompt) > 0 && self.noTurnIsRunning()
            }, timeout: 30), "The chat turn \(prompt) should finish.")
        }
        let arguments = try XCTUnwrap(fixtureTurns().last?["arguments"] as? [String])
        let instructions = arguments[try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt")) + 1]
        XCTAssertTrue(instructions.contains("before you write your final reply"), "The instructions must put close-turn before the final reply.")
        XCTAssertTrue(instructions.contains("never end a turn on a tool call"))
        XCTAssertTrue(instructions.contains("Run exactly one close-turn per turn"))
        XCTAssertTrue(instructions.contains("never just write it as text in your reply"))
        XCTAssertTrue(instructions.contains("never write the page name"))
        XCTAssertTrue(instructions.contains("previous response had no visible output but you already answered in this turn, do not repeat the answer"))
        XCTAssertFalse(instructions.contains("At the end of every single turn"))
        XCTAssertFalse(instructions.contains("CRITICAL, READ FIRST"), "No hidden escalation is prepended to the chat instructions.")

        // close-turn first, then the reply: one visible final answer, filed, and no nudge.
        let closeFirstPrompt = "Name the largest moon of Jupiter."
        let closeFirstAnswer = "Ganymede is the largest moon of Jupiter."
        send(closeFirstPrompt)
        XCTAssertTrue(visibleTexts(containing: closeFirstAnswer).firstMatch.waitToExist(timeout: 10),
                      "The reply written after close-turn is the visible response.")
        XCTAssertEqual(try turnMessages(prompt: closeFirstPrompt).map { "\($0.0)|\($0.1 ?? "")|\($0.2)" },
                       ["user||\(closeFirstPrompt)", "assistant|final_answer|\(closeFirstAnswer)"],
                       "The close-turn-first turn holds exactly one final answer.")
        XCTAssertEqual(nudgeCount(), 0, "A turn whose close-turn ran is settled, so Playhouse sends it no nudge.")
        let activePageID = try XCTUnwrap(((try runCLI(["chat", "status"])["result"] as? [String: Any])?["activePage"] as? [String: Any])?["id"] as? String)
        func pageTexts() throws -> [String] {
            try XCTUnwrap((try runCLI(["chat", "page", "read", activePageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
                .compactMap { $0["text"] as? String }
        }
        XCTAssertTrue(try pageTexts().contains(closeFirstAnswer), "The close-turn-first turn is filed onto the active page.")
        attachScreenshot(named: "standalone-chat-close-turn-first-single-answer")

        // Claude Code's own no-visible-output notice: an automatic message from Claude Code,
        // between the answer and a separate reply, never merged into one bubble.
        let noticePrompt = "Name the largest moon of Saturn."
        let noticeAnswer = "Titan is the largest moon of Saturn."
        let noticeReply = "I already answered above."
        let noticeText = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
        send(noticePrompt)
        XCTAssertTrue(visibleTexts(containing: noticeAnswer).firstMatch.waitToExist(timeout: 10), "The answer stays visible.")
        XCTAssertTrue(visibleTexts(containing: noticeReply).firstMatch.waitToExist(timeout: 5), "The reply after the notice is visible as its own message.")
        let noticeBubble = try assertAutomaticMessageBubble(taskID: chatID, containing: noticeText, sender: "Claude Code")
        XCTAssertLessThan(visibleTexts(containing: noticeAnswer).firstMatch.frame.minY, noticeBubble.frame.minY, "The notice follows the answer.")
        XCTAssertLessThan(noticeBubble.frame.minY, visibleTexts(containing: noticeReply).firstMatch.frame.minY, "The reply follows the notice.")
        XCTAssertFalse(transcriptContains("Claude Code automatic notice:"), "The notice's internal marker line is never shown.")
        XCTAssertEqual(
            app.groups.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", noticeAnswer, noticeReply)).count, 0,
            "No bubble may hold the answer together with what Claude wrote after the notice."
        )
        XCTAssertEqual(try turnMessages(prompt: noticePrompt).map { "\($0.0)|\($0.1 ?? "")|\($0.2)" }, [
            "user||\(noticePrompt)",
            "assistant|final_answer|\(noticeAnswer)",
            "user||Claude Code automatic notice:\n\(noticeText)",
            "assistant|final_answer|\(noticeReply)",
        ], "Fresh history keeps the answer, the notice and the reply apart, in turn order.")
        XCTAssertFalse(try pageTexts().contains { $0.contains(noticeText) }, "Claude Code's notice is never filed into a chat page.")
        XCTAssertTrue(try pageTexts().contains(noticeReply))
        XCTAssertEqual(nudgeCount(), 0, "The notice turn ran close-turn, so it gets no Playhouse nudge.")
        attachScreenshot(named: "standalone-chat-claude-code-notice-is-automatic")
    }
    // case-contract: test_standalone_chat_missed_close_turn_gets_visible_nudge | When a standalone chat turn ends without its chat page close-turn signal, Playhouse sends exactly one follow-up turn through the same unsettled-turn recovery loop task conversations use. Its prompt starts with the Playhouse nudge marker, asks for close-turn on the previous reply and never for a task outcome, and stays in the chat transcript as an automatic message from Playhouse, followed by the agent's reply. A close-turn run in that nudge settles the turn and classifies the user's turn, which moves to the new titled page without the fallback classifier; the nudge turn and its reply are never filed into a chat page or replayed into a page's seeded context. A nudge that goes unanswered is not retried, the background classifier then decides the page, the chat never gets a board status such as Blocked, and task outcome is rejected for the chat. The nudge loop, the close-turn CLI and the turn outcome store are shared by Claude and Codex, so one representative provider (Claude) covers this case, and the round-trip case shows a Codex chat turn reaching the same nudge.
    func test_standalone_chat_missed_close_turn_gets_visible_nudge() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-close-turn-nudge")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        let prompt = "Plan a weekend hiking trip."
        let answer = "Pick a loop trail under 15 km and start early."
        func visibleTexts(containing text: String) -> XCUIElementQuery {
            app.groups.matching(NSPredicate(format: "label CONTAINS %@", text))
        }
        func fixtureTurns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter {
                !((($0["userText"] as? String) ?? "").hasPrefix("Classify the latest user message"))
            }
        }
        func nudgeTurns() -> [[String: Any]] {
            fixtureTurns().filter { (($0["userText"] as? String) ?? "").contains("Playhouse internal outcome nudge:") }
        }
        func chatStatus() throws -> [String: Any] {
            try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        }
        func send(_ text: String) {
            let composer = element("message-composer")
            XCTAssertTrue(composer.waitToExist(timeout: 10))
            composer.click()
            composer.typeText(text)
            element("send-message-button").click()
        }

        // The turn answers but never runs close-turn: one visible nudge follows, which the
        // agent answers by running close-turn for that reply.
        send(prompt)
        XCTAssertTrue(waitUntil({ nudgeTurns().count == 1 && self.noTurnIsRunning() }, timeout: 30),
                      "A chat turn that skipped close-turn gets exactly one nudge, and the chat settles.")
        let nudge = try XCTUnwrap(nudgeTurns().first)
        let nudgeText = (nudge["userText"] as? String) ?? ""
        XCTAssertTrue(nudgeText.contains("chat page close-turn \(chatID)"), "The chat nudge asks for close-turn on the previous reply.")
        XCTAssertFalse(nudgeText.contains("task outcome"), "A chat is never asked for a task outcome.")
        XCTAssertTrue(((nudge["reportCommands"] as? [[String: Any]])?.first?["output"] as? String ?? "").contains("\"ok\":true"))
        XCTAssertTrue(visibleTexts(containing: answer).firstMatch.waitToExist(timeout: 10), "The answer stays visible above the nudge.")
        let nudgeBubble = try assertAutomaticMessageBubble(taskID: chatID, containing: "This is the only reminder for that reply.")
        let replyBubble = visibleTexts(containing: "Filed.").firstMatch
        XCTAssertTrue(replyBubble.waitToExist(timeout: 5), "The agent's reply to the nudge is visible.")
        let answerBubble = visibleTexts(containing: answer).firstMatch
        XCTAssertLessThan(answerBubble.frame.minY, nudgeBubble.frame.minY, "The nudge follows the answer it is about.")
        XCTAssertLessThan(nudgeBubble.frame.minY, replyBubble.frame.minY, "The agent's reply follows the nudge.")
        XCTAssertFalse(transcriptContains("Playhouse internal outcome nudge:"), "The nudge's internal marker line is never shown.")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Hiking trip") }, timeout: 10),
                      "The nudge's close-turn moves the user's turn to its new titled page.")
        // The turn is filed after the nudge loop, so its page contents can land just after the turn settles.
        var hikingPage: [String: Any] = [:]
        var pageTexts: [String] = []
        XCTAssertTrue(waitUntil({
            guard let status = try? chatStatus(),
                  status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any],
                  page["title"] as? String == "Hiking trip",
                  let pageID = page["id"] as? String,
                  let messages = (try? self.runCLI(["chat", "page", "read", pageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] else { return false }
            hikingPage = page
            pageTexts = messages.compactMap { $0["text"] as? String }
            return pageTexts == [prompt, answer]
        }, timeout: 15), "Only the user's turn is filed on its page, never the nudge or its reply: \(pageTexts)")
        XCTAssertEqual(hikingPage["title"] as? String, "Hiking trip")
        let history = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        XCTAssertFalse(String(decoding: history, as: UTF8.self).contains("Classify the latest user message"),
                       "A nudge that got close-turn run leaves nothing for the fallback classifier.")
        let chatState = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["status"] as? String)
        XCTAssertTrue(["In Progress", "Waiting Response"].contains(chatState), "A chat nudge never sets a board status such as Blocked.")
        assertCLIError(try runCLI(["task", "outcome", chatID, "completed"], expectedStatus: 2), code: "invalid_argument")
        attachScreenshot(named: "standalone-chat-close-turn-nudge-is-visible")

        // A second missed turn whose nudge goes unanswered: one nudge, no Blocked, and the
        // background classifier decides the page. The new page's session is seeded with its own
        // turn, never with the nudge or its reply.
        send("Tell me about volcanoes")
        XCTAssertTrue(waitUntil({
            guard nudgeTurns().count == 2, self.noTurnIsRunning(),
                  let status = try? chatStatus(),
                  status["missedPreviousPageSignal"] as? Bool == false,
                  (status["activePage"] as? [String: Any])?["title"] as? String == "Volcanoes" else { return false }
            return true
        }, timeout: 45), "An unanswered nudge leaves the page to the fallback classifier.")
        XCTAssertEqual((nudgeTurns().last?["reportCommands"] as? [Any])?.count, 0, "This nudge goes unanswered.")
        let seeded = try XCTUnwrap(fixtureTurns().first { (($0["userText"] as? String) ?? "").hasSuffix("Tell me about volcanoes") }?["userText"] as? String)
        XCTAssertTrue(seeded.contains(prompt) && seeded.contains(answer), "The new page's session is seeded with its own turn.")
        XCTAssertFalse(seeded.contains("Playhouse internal outcome nudge:"), "A nudge is never replayed into page context.")
        XCTAssertFalse(seeded.contains("Filed."), "A nudge's reply is never replayed into page context.")
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Volcanoes") }, timeout: 10))
        try assertAutomaticMessageBubble(taskID: chatID, containing: "This is the only reminder for that reply.")
        XCTAssertEqual(nudgeTurns().count, 2, "An unanswered chat nudge is not retried.")
        let laterState = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["status"] as? String)
        XCTAssertTrue(["In Progress", "Waiting Response"].contains(laterState), "An unanswered chat nudge never marks the chat Blocked.")
        attachScreenshot(named: "standalone-chat-unanswered-nudge-falls-back")
    }
    // case-contract: test_standalone_chat_recalls_loaded_pages | When a standalone chat's agent loads an earlier page into its context with `chat page read`, the conversation renders one deterministic "Recalling <page title>" line per loaded page, titled from the page archive rather than from anything the agent wrote, in the order the pages were read. The lines are visible in the turn that read them without opening the Worked for disclosure, stay once the turn settles and after a later turn and a reopen, and the read commands really run and succeed so the history carries each call and the page's own title. The line is derived from Playhouse's own provider-neutral command activity (a shell call titled "Running <command>" for both Claude and Codex) and the page store, so provider selection cannot change it; one representative provider (Claude) covers the shared path.
    func test_standalone_chat_recalls_loaded_pages() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-recall")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        _ = try runCLI(["chat", "open"])
        let titles = ["Volcano research", "Saturn notes"]
        var pageIDs: [String] = []
        for title in titles {
            let page = try XCTUnwrap(
                (try runCLI(["chat", "page", "new", "--title", title])["result"] as? [String: Any])?["page"] as? [String: Any]
            )
            pageIDs.append(try XCTUnwrap(page["id"] as? String))
        }
        _ = try runCLI(["chat", "page", "new", "--title", "Current topic"])

        func recallRow(_ index: Int) -> XCUIElement { element("conversation-chat-page-recall-toolu_recall_\(index)") }
        func send(_ prompt: String) {
            let composer = element("message-composer")
            XCTAssertTrue(composer.waitToExist(timeout: 10))
            composer.click()
            composer.typeText(prompt)
            element("send-message-button").click()
        }

        func waitForRecallLabel(_ index: Int, _ title: String) -> Bool {
            waitUntil({ recallRow(index).exists && recallRow(index).label == "Recalling \(title)" }, timeout: 10)
        }
        let hold = URL(fileURLWithPath: executable.path + ".recall-hold")
        let ready = URL(fileURLWithPath: executable.path + ".recall-ready")
        let release = URL(fileURLWithPath: executable.path + ".recall-release")
        try Data().write(to: hold)
        let prompt = "recall-earlier-pages " + pageIDs.map { "page-id:\($0)" }.joined(separator: " ")
        send(prompt)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 30),
                      "The recalling turn should be held open after its reads.")
        XCTAssertFalse(self.noTurnIsRunning(), "The turn is still running while the lines are checked.")
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitForRecallLabel(index, title), "A Recalling line for \(title) should render the moment its read is seen, while the turn runs.")
        }
        XCTAssertLessThan(recallRow(0).frame.minY, recallRow(1).frame.minY, "Lines render in the order the pages were read.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversation-chat-page-recall-toolu_recall_0").count, 1,
                       "A live page read renders as one Recalling line, not again as a command row in the work list.")
        XCTAssertEqual(element("codex-activity-details").descendants(matching: .any)
            .matching(identifier: "conversation-chat-page-recall-toolu_recall_0").count, 0,
                       "The line stands on its own rather than inside the work disclosure.")
        attachScreenshot(named: "standalone-chat-recalling-lines-live")
        try Data().write(to: release)
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: "recall-earlier-pages") > 0 && self.noTurnIsRunning()
        }, timeout: 30), "The recalling turn should finish.")
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitForRecallLabel(index, title), "The line for \(title) stays once the turn settles.")
        }
        let disclosure = element("codex-activity-disclosure")
        XCTAssertTrue(disclosure.waitToExist(timeout: 20), "The settled turn shows its Worked for summary.")
        XCTAssertTrue((disclosure.value as? String ?? "").hasPrefix("Collapsed"), "Worked for stays collapsed while the lines are visible.")
        attachScreenshot(named: "standalone-chat-recalling-lines")

        send("recall-earlier-pages")
        XCTAssertTrue(waitUntil({
            self.fixtureTurnCount(executable, containing: "recall-earlier-pages") > 1 && self.noTurnIsRunning()
        }, timeout: 30), "A later turn should finish.")
        XCTAssertTrue(revealWholeTranscript(), "The earlier turn should load as the reader scrolls up.")
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitForRecallLabel(index, title), "The Recalling line for \(title) should stay after a later turn.")
        }
        attachScreenshot(named: "standalone-chat-recalling-lines-after-later-turn")

        refreshStandaloneChatSidebar()
        XCTAssertTrue(revealWholeTranscript(), "The reopened chat should load its earlier turn as the reader scrolls up.")
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitForRecallLabel(index, title), "The Recalling line for \(title) should survive reopening the chat.")
        }
    }
    // case-contract: test_standalone_chat_claude_fallback_classifier | When a standalone chat uses Claude, a missed page signal invokes the Haiku helper at low effort; a malformed result is rejected and retried, an unrelated later question and its assistant reply move to a new titled page, the UI keeps page evaluation visually quiet without blocking the primary answer, updates the transcript separator when classification completes, and holds a following send until the decision resolves, and appends the related follow-up in chronological order. The Claude-specific model and effort arguments are verified through the real CLI/XPC path. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes.
    func test_standalone_chat_claude_fallback_classifier() throws {
        let executable = dataDirectory.appendingPathComponent("claude-fixture-chat-page-fallback")
        try copyFixtureFile(
            at: WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui"),
            to: executable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner")
        )
        claudeFixtureExecutable = executable.path
        _ = try runCLI(["settings", "set-default-provider", "claude"])
        _ = try runCLI(["settings", "clear-parent"])
        launchApp(defaultParent: nil)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        let opened = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any]))
        XCTAssertNotNil(opened["id"] as? String)
        XCTAssertEqual(opened["conversationProvider"] as? String, "claude")
        let firstPage = try XCTUnwrap(
            (try runCLI(["chat", "page", "new", "--title", "General chat"])["result"] as? [String: Any])?["page"] as? [String: Any]
        )

        func sendFromSidebar(_ prompt: String, expectedTitle: String) throws {
            let composer = element("message-composer")
            XCTAssertTrue(composer.waitToExist(timeout: 10))
            let hold = URL(fileURLWithPath: executable.path + ".hold-classifier")
            let active = URL(fileURLWithPath: executable.path + ".classifier-active")
            let release = URL(fileURLWithPath: executable.path + ".classifier-release")
            if prompt == "Tell me about volcanoes" { try Data().write(to: hold) }
            // Waits for the chat to settle and the click to focus the composer before typing.
            typeIntoField(composer, text: prompt)
            XCTAssertTrue(element("send-message-button").isEnabled, "Standalone chat should remain sendable without a repository parent.")
            element("send-message-button").click()
            if prompt == "Tell me about volcanoes" {
                XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: active.path) }, timeout: 15), "The Haiku fallback should remain held after the primary Claude turn finishes.")
                XCTAssertFalse(element("chat-active-page-title").exists, "Page titles should appear in transcript separators, not the header.")
                XCTAssertFalse(element("chat-missed-page-signal-notice").exists, "Page evaluation should stay visually quiet while pending.")
                XCTAssertEqual(element("chat-sidebar").descendants(matching: .progressIndicator).count, 0, "Page evaluation should not show a loader in the chat sidebar.")
                XCTAssertTrue(transcriptMessage("OK.").waitToExist(timeout: 10), "The primary Claude answer should be visible while fallback classification is pending.")
                XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "A background classifier must not keep the chat turn running.")
                XCTAssertTrue(chatPageSeparatorIsVisible("General chat"))
                return
            }
            if prompt == "Tell me about Saturn's rings" {
                XCTAssertFalse(
                    waitUntil({ self.fixtureTurnCount(executable, containing: prompt) > 0 }, timeout: 3),
                    "The queued Claude turn should wait for the prior page decision."
                )
                try Data("Release classifier.\n".utf8).write(to: release)
            }
            XCTAssertTrue(waitUntil({
                guard self.chatPageSeparatorIsVisible(expectedTitle),
                      let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any] else { return false }
                return status["missedPreviousPageSignal"] as? Bool == false
            }, timeout: 30), "The Haiku fallback should persist and visibly show the title \(expectedTitle).")
            XCTAssertFalse(element("chat-missed-page-signal-notice").exists)
        }

        try sendFromSidebar("Tell me about volcanoes", expectedTitle: "Volcanoes")
        try sendFromSidebar("Tell me about Saturn's rings", expectedTitle: "Saturn Rings")
        try sendFromSidebar("One more thought about Saturn", expectedTitle: "Saturn Rings")

        XCTAssertTrue(waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any],
                  page["title"] as? String == "Saturn Rings",
                  let pageID = page["id"] as? String,
                  let messages = (try? self.runCLI(["chat", "page", "read", pageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] else { return false }
            return messages.compactMap { $0["text"] as? String } == [
                "Tell me about Saturn's rings", "OK.", "One more thought about Saturn", "OK.",
            ]
        }, timeout: 30), "The related follow-up must finish on the selected page in transcript order.")

        let status = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        let activePage = try XCTUnwrap(status["activePage"] as? [String: Any])
        XCTAssertNotEqual(activePage["id"] as? String, firstPage["id"] as? String)
        let firstMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(firstPage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        let activeMessages = try XCTUnwrap(
            (try runCLI(["chat", "page", "read", try XCTUnwrap(activePage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        XCTAssertTrue(firstMessages.contains { ($0["role"] as? String) == "user" && ($0["text"] as? String) == "Tell me about volcanoes" })
        XCTAssertTrue(firstMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "OK." })
        XCTAssertEqual(firstMessages.filter { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "OK." }.count, 1, "The Saturn assistant reply must not remain duplicated on the Volcanoes page.")
        XCTAssertEqual(activeMessages.map { $0["text"] as? String }, [
            "Tell me about Saturn's rings", "OK.", "One more thought about Saturn", "OK.",
        ], "A related turn after fallback must append in chronological order.")
        XCTAssertFalse(firstMessages.contains { ($0["text"] as? String) == "Tell me about Saturn's rings" })
        let pages = try XCTUnwrap((try runCLI(["chat", "page", "list"])["result"] as? [String: Any])?["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(Set(pages.compactMap { $0["title"] as? String }), Set(["Volcanoes", "Saturn Rings"]))
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        let turns = try XCTUnwrap(history?["turns"] as? [[String: Any]])
        let classifications = turns.filter { ($0["userText"] as? String)?.hasPrefix("Classify the latest user message for Playhouse's continuous chat page index.") == true }
        XCTAssertEqual(classifications.count, 4, "The fallback should retry one malformed result and classify a later follow-up.")
        for turn in classifications {
            XCTAssertEqual(turn["effort"] as? String, "low")
            let arguments = try XCTUnwrap(turn["arguments"] as? [String])
            let modelArgumentIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
            XCTAssertEqual(arguments[modelArgumentIndex + 1], "haiku")
        }

        let priorPageID = try XCTUnwrap(activePage["id"] as? String)
        let hold = URL(fileURLWithPath: executable.path + ".hold-classifier")
        let active = URL(fileURLWithPath: executable.path + ".classifier-active")
        let release = URL(fileURLWithPath: executable.path + ".classifier-release")
        try? FileManager.default.removeItem(at: active)
        try? FileManager.default.removeItem(at: release)
        try Data().write(to: hold)
        let composer = element("message-composer")
        typeIntoField(composer, text: "Tell me about Neptune")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: active.path) }, timeout: 15))
        let explicitPage = try XCTUnwrap((try runCLI(["chat", "page", "new", "--title", "Explicit topic"])["result"] as? [String: Any])?["page"] as? [String: Any])
        refreshStandaloneChatSidebar()
        // A page's title separator is drawn before its first message, so the new page shows
        // once a turn lands on it (asserted after the Mars send below).
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists)
        try Data("Release classifier.\n".utf8).write(to: release)
        XCTAssertTrue(waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  let page = status["activePage"] as? [String: Any] else { return false }
            return (page["id"] as? String) == (explicitPage["id"] as? String)
        }, timeout: 30))
        let explicitMessages = try XCTUnwrap((try runCLI(["chat", "page", "read", try XCTUnwrap(explicitPage["id"] as? String)])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(explicitMessages.isEmpty)
        let oldPageMessages = try XCTUnwrap((try runCLI(["chat", "page", "read", priorPageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        XCTAssertTrue(oldPageMessages.contains { ($0["text"] as? String) == "Tell me about Neptune" })
        XCTAssertTrue(oldPageMessages.contains { ($0["role"] as? String) == "assistant" && ($0["text"] as? String) == "OK." })

        let classifierFailure = URL(fileURLWithPath: executable.path + ".fail-classifier")
        try Data().write(to: classifierFailure)
        typeIntoField(composer, text: "Tell me about Mars")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["chat", "status"])["result"] as? [String: Any])?["missedPreviousPageSignal"] as? Bool == true
        }, timeout: 30))
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Explicit topic") }, timeout: 10), "The explicit page's title should appear with its first message.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "The Mars turn should finish before the next send.")
        typeIntoField(composer, text: "Do not overtake Mars")
        element("send-message-button").click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 15), "Claude chat should explain when a prior page decision is still unresolved.")
        let failedHistory = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))) as? [String: Any]
        let failedTurns = try XCTUnwrap(failedHistory?["turns"] as? [[String: Any]])
        XCTAssertFalse(failedTurns.contains { ($0["userText"] as? String) == "Do not overtake Mars" })
        try FileManager.default.removeItem(at: classifierFailure)
        _ = try runCLI(["chat", "status"])
        let retryStatus = try XCTUnwrap(try runCLI(["chat", "status"])["result"] as? [String: Any])
        XCTAssertFalse(retryStatus["missedPreviousPageSignal"] as? Bool ?? true)
        XCTAssertEqual((retryStatus["activePage"] as? [String: Any])?["title"] as? String, "Mars")
        refreshStandaloneChatSidebar()
        XCTAssertTrue(waitUntil({ self.chatPageSeparatorIsVisible("Mars") }, timeout: 10))
        XCTAssertFalse(element("chat-missed-page-signal-notice").exists)
        focusField(composer)
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("Another thought about Mars")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            guard let status = try? self.runCLI(["chat", "status"])["result"] as? [String: Any],
                  status["missedPreviousPageSignal"] as? Bool == false,
                  let page = status["activePage"] as? [String: Any],
                  page["title"] as? String == "Mars",
                  let pageID = page["id"] as? String,
                  let messages = (try? self.runCLI(["chat", "page", "read", pageID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] else { return false }
            return messages.contains { ($0["text"] as? String) == "Another thought about Mars" }
        }, timeout: 30))
    }
    // case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while the composer automatically saves an unsent prompt as it is typed; clearing the composer clears the stored draft, backing out needs no Save button, and reopening restores the draft without creating a branch or worktree. Blank drafts cannot be stored, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text. A prompt saved through the CLI without submitting is an unsent draft, so the composer shows it when the task is reopened. A send that fails before any turn starts, such as one into a folder that no longer exists, returns its prompt to the composer as the draft, clears the pending marker and leaves the task out of In Progress.
    func test_task_prompt_draft_persists_after_back() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-success-wait").path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10), "Task creation should open its conversation immediately.")
        XCTAssertFalse(element("save-task-prompt-button").exists, "Drafts should save automatically without a separate Save button.")
        let initialTask = try XCTUnwrap(tasksFromBoardList().first)
        let selectedRepository = try XCTUnwrap((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["repositoryPath"] as? String)
        XCTAssertEqual(selectedRepository, fixture.primary.path)
        let initialBranch = try XCTUnwrap((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["branch"] as? String)
        XCTAssertEqual(initialBranch, "auto")
        XCTAssertEqual((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["isPending"] as? Bool, true)
        XCTAssertEqual((initialTask["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String, fixture.primary.path)
        let prompt = "Please update the README and explain the change."
        composer.click()
        composer.typeText(prompt)
        let taskID = try XCTUnwrap(initialTask["id"] as? String)
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) ?? nil) == prompt
        }, timeout: 10), "The draft should persist while it is being typed.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) == nil
        }, timeout: 10), "Clearing the composer should clear the persisted draft.")
        composer.typeText(prompt)
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["savedPrompt"] as? String) ?? nil) == prompt
        }, timeout: 10), "Typing again should autosave the replacement draft.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        let titleGenerationReady = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-ready")
        let titleGenerationContinue = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-continue")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: titleGenerationReady.path) }, timeout: 10), "The real app-server fixture should confirm that title generation is in flight.")
        let tasks = try tasksFromBoardList()
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task["id"] as? String, taskID)
        let response = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(response?["savedPrompt"] as? String, prompt)
        XCTAssertEqual(response?["status"] as? String, "Backlog")
        let invalid = try runCLI(["task", "prompt", taskID, "--text", "Changed", "--status", "Not a status"], expectedStatus: 2)
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let doneTransition = try runCLI(["task", "prompt", taskID, "--text", "Changed", "--status", "Done"], expectedStatus: 2)
        XCTAssertEqual((doneTransition["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let unchanged = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(unchanged?["savedPrompt"] as? String, prompt)
        XCTAssertEqual(unchanged?["status"] as? String, "Backlog")

        _ = try runCLI(["task", "rename", taskID, "--title", "Stable draft title"])
        try Data("continue\n".utf8).write(to: titleGenerationContinue)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: titleGenerationReady.path) }, timeout: 10), "The fixture should finish the delayed title turn.")
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["title"] as? String) ?? nil) == "Stable draft title"
        }, timeout: 10), "A late title response must not overwrite a title that was renamed while generation was pending.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains { $0["taskID"] as? String == taskID && $0["event"] as? String == "task.title_apply.skipped" }) == true
        }, timeout: 10), "The late result should be logged as skipped after the user renames the task.")
        let titleEvents = try diagnosticEvents().filter { $0["taskID"] as? String == taskID }
        let skippedTitle = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_apply.skipped" })
        XCTAssertEqual(skippedTitle["reason"] as? String, "title_changed")
        XCTAssertEqual(skippedTitle["currentTitleState"] as? String, "custom")
        XCTAssertEqual(skippedTitle["titleSource"] as? String, "codex")
        let serializedTitleEvents = String(data: try JSONSerialization.data(withJSONObject: titleEvents), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedTitleEvents.contains(prompt), "Title diagnostics must not include conversation text.")
        XCTAssertFalse(serializedTitleEvents.contains("Stable draft title"), "Title diagnostics must not include a user-renamed title.")
        openTask(named: "Stable draft title")
        XCTAssertEqual(composer.value as? String, prompt, "Reopening should restore an unsent draft.")
        element("back-to-board-button").click()
        // A prompt written through the CLI without submitting is the composer's unsent draft too.
        _ = try runCLI(["task", "prompt", taskID, "--text", "Written by the CLI."])
        openTask(named: "Stable draft title")
        XCTAssertTrue(waitUntil({
            (composer.value as? String) == "Written by the CLI."
        }, timeout: 10), "A prompt saved through the CLI without submitting should appear in the composer.")
        attachScreenshot(named: "Prompt written through the CLI is restored to the composer")
        element("back-to-board-button").click()
        let stableTitle = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(stableTitle?["title"] as? String, "Stable draft title", "Returning with the saved draft should not restart title generation.")
        attachScreenshot(named: "Unsent task prompt is saved after returning to backlog")

        // A send that fails before any turn starts returns its prompt to the composer as the draft.
        let goneRoot = fixture.parent.appendingPathComponent("failed-send-root", isDirectory: true)
        try FileManager.default.createDirectory(at: goneRoot, withIntermediateDirectories: true)
        try createTaskFixture(title: "Failed send draft", roots: [goneRoot.path])
        try FileManager.default.removeItem(at: goneRoot)
        let failedTaskID = try XCTUnwrap(try taskRecord(named: "Failed send draft")?["id"] as? String)
        let failedPrompt = "Send this to a folder that is gone."
        _ = try runCLI(["conversation", "send", failedTaskID, "--message", failedPrompt], expectedStatus: 1)
        let returnedRecord = try XCTUnwrap(try taskRecord(id: failedTaskID))
        XCTAssertEqual(returnedRecord["hasUnsentDraft"] as? Bool, true, "A send that never started a turn returns its prompt as the draft.")
        XCTAssertEqual(returnedRecord["savedPrompt"] as? String, failedPrompt)
        XCTAssertNil(returnedRecord["pendingSubmittedPrompt"] as? String)
        XCTAssertNotEqual(returnedRecord["status"] as? String, "In Progress")
        openTask(named: "Failed send draft")
        XCTAssertTrue(waitUntil({
            (self.element("message-composer").value as? String) == failedPrompt
        }, timeout: 10), "A prompt whose send never started a turn should be back in the composer.")
        attachScreenshot(named: "Prompt from a send that never started is back in the composer")
        element("back-to-board-button").click()
    }
}

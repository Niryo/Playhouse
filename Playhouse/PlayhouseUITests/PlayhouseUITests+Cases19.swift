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
    // case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode keeps planning active across completed turns and reopening; follow-up instructions start another plan turn, and Start Implementing is hidden until a first message is sent and while the agent waits on answers to its questions, then stays enabled with an empty composer, switches to Code mode, and starts an implementation turn; subsequent composer messages remain Code turns. The plan renders automatically as Markdown with visible spacing, remains selectable and copyable as one complete text view, and CLI events and bridge history preserve the exact plan text and latest implementation handoff. Ordered list items stay on separate lines instead of being merged, including a list that starts on the line right after a paragraph without a blank line, a list that starts at 2 after a heading (rendered as items 2-5 with their real numbers, while a "3. " line inside a paragraph stays prose), and a fenced code block renders as a distinct block with its declared language label and a copy action that places its exact source on the pasteboard. A Markdown pipe table renders as a distinct bordered grid with a header row and data rows instead of raw pipe/dash text, preserving cell content and column alignment and wrapping a long cell onto every line it needs instead of cutting it off with an ellipsis, while CLI/XPC history preserves the exact raw table source text. Multiple plan deltas are summarized per item with count and byte totals at turn completion, with no per-delta notification records and no plan text in diagnostics. While the first plan is still streaming in and fits the viewport, the question that started it stays pinned near the top of the transcript, consistent with the user message preceding its final answer in CLI/XPC history. The plan streams in four held deltas that end inside a paragraph, inside a list item after it, and inside the fenced code block; CLI/XPC events carry exactly those deltas in order, and at each held stage the plan's one prose text view and its code block show exactly the text streamed so far, with nothing repeated or left over from an earlier stage, before the completed plan shows its whole code block.
    func test_plan_mode_renders_markdown_in_conversation() throws {
        let fixtureRoot = WorkspaceFixture.root
        let fixtureOwnerMarker = fixtureRoot.appendingPathComponent(".playhouse-bridge-fixture")
        XCTAssertEqual(
            try String(contentsOf: fixtureOwnerMarker, encoding: .utf8),
            "Playhouse bridge tests own this deterministic fixture (v1).\n",
            "Refusing to use a Codex fixture in a directory Playhouse does not own."
        )
        let fixtureCopy = fixtureRoot.appendingPathComponent("codex-fixture-markdown")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the Markdown fixture before launch.")
        let deltaHold = URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-hold")
        func deltaReady(_ stage: Int) -> URL { URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-ready-\(stage)") }
        func releaseDelta(_ stage: Int) throws {
            try Data().write(to: URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-release-\(stage)"))
        }
        try Data().write(to: deltaHold)
        codexFixtureExecutable = fixtureCopy.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Plan mode Markdown", roots: [fixture.primary.path])
        openTask(named: "Plan mode Markdown")

        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 10))
        modeMenu.click()
        let planMode = app.menuItems["Plan mode"]
        XCTAssertTrue(planMode.waitToExist(timeout: 5))
        planMode.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))

        let taskID = try taskID(named: "Plan mode Markdown")
        let emptyConversation = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((emptyConversation?["messages"] as? [[String: Any]])?.count ?? 0, 0, "The handoff availability check should start with an empty conversation.")
        XCTAssertEqual(element("message-composer").value as? String ?? "", "")
        let startImplementingInEmptyConversation = element("start-implementing-button")
        XCTAssertFalse(startImplementingInEmptyConversation.waitToExist(timeout: 2), "Plan mode should not offer Start Implementing before a first message exists.")

        modeMenu.click()
        let goalComposerMode = app.menuItems["conversation-mode-goal"]
        XCTAssertTrue(goalComposerMode.waitToExist(timeout: 5))
        goalComposerMode.click()
        XCTAssertTrue(modeMenu.label.contains("Goal"), "The composer should enter Goal mode.")
        XCTAssertFalse(startImplementingInEmptyConversation.exists, "Entering Goal mode should not reveal Start Implementing in an empty conversation.")
        modeMenu.click()
        let planModeAfterGoal = app.menuItems["Plan mode"]
        XCTAssertTrue(planModeAfterGoal.waitToExist(timeout: 5))
        planModeAfterGoal.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Plan mode should be selectable again after Goal.")
        let composer = element("message-composer")

        composer.click()
        composer.typeText("Plan the task.")
        element("send-message-button").click()
        let markdownReply = "## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n\nTwo numbered steps follow on the very next lines:\n1. First numbered step: capture the baseline state before changes.\n\n2. Second numbered step: apply the fix and confirm there are no regressions.\n\n```javascript\nconsole.log(\"Hello, world!\");\n```\n\n| Step | Status |\n| --- | :---: |\n| Verify fixture | Done |\n| Render table | Pending |\n| Wrap long cell | This status note is deliberately long so that it has to wrap onto several lines inside its column instead of being cut off with an ellipsis, and it keeps going for a while longer so that even a wide window still needs at least three lines to show every word of it |\n\n## Still open\n\n2. Open question two: should the installed app differ from the dev build?\n3. Open question three: when should the app restart?\n4. Open question four: which version numbers do we use?\n5. Open question five: may we use the local test feed?\n\nModel sizes vary a lot in practice, and\n3. 5 billion parameters is a common size."
        let assistantMarkdown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Implementation plan"))
            .firstMatch
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: deltaReady(1).path) }, timeout: 10), "The fixture should pause after the first plan delta.")
        XCTAssertTrue(assistantMarkdown.waitToExist(timeout: 10), "The first plan delta should appear before the turn completes.")
        // The streamed message can be replaced by its persisted item; read the partial plan once.
        let partialPlan = assistantMarkdown.label
        XCTAssertTrue(partialPlan.contains("workspace model"), "The partial plan should show its streamed content.")
        XCTAssertTrue(partialPlan.contains("\n\n"), "Distinct Markdown paragraphs should retain visible spacing.")
        XCTAssertFalse(partialPlan.contains("Final verification"), "The rest of the plan should wait for the fixture release.")
        let planQuestion = transcriptMessage("Plan the task.")
        let planTranscriptScrollView = element("conversation-scroll-view")
        XCTAssertTrue(planQuestion.waitToExist(timeout: 5))
        XCTAssertTrue(waitUntil({
            planQuestion.frame.minY >= planTranscriptScrollView.frame.minY - 4
                && planQuestion.frame.minY <= planTranscriptScrollView.frame.minY + 120
        }, timeout: 5), "While the partial plan still fits below it, the question that started the turn should stay pinned near the top of the transcript; question=\(planQuestion.frame), viewport=\(planTranscriptScrollView.frame).")

        // The streaming plan grows in place: each held stage shows exactly the text streamed so
        // far, ending inside a paragraph, then a list item after it, then the code block.
        let streamingProse = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Implementation plan")).firstMatch
        // Matching on value across the whole transcript times out, so look only inside the code card.
        let streamingCode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "assistant-markdown-code-block-[0-9]+"))
            .firstMatch
            .descendants(matching: .any).matching(NSPredicate(format: "value BEGINSWITH %@", "console.log("))
            .firstMatch
        let planOpening = ["Implementation plan", "Start with the workspace model."]
        let fullSecondParagraph = "A separate paragraph confirms readable spacing between plan sections."
        func detail(_ number: Int) -> String {
            String(format: "•\tImplementation detail %02d: verify the saved conversation state and rendered result", number)
        }
        func assertStreamedProse(_ lines: [String], stage: Int) {
            let expected = lines.joined(separator: "\n")
            XCTAssertTrue(waitUntil({ streamingProse.exists && streamingProse.value as? String == expected }, timeout: 10),
                          "Stage \(stage) should show exactly the plan streamed so far, with nothing repeated or left over from earlier stages; shown=\(String(describing: streamingProse.value)), expected=\(expected)")
        }
        assertStreamedProse(planOpening + ["A s"], stage: 1)
        try releaseDelta(1)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: deltaReady(2).path) }, timeout: 10), "The fixture should pause after the second plan delta.")
        assertStreamedProse(planOpening + [fullSecondParagraph] + (1...10).map(detail) + ["•\tImplementation detail 11: verify"], stage: 2)
        attachScreenshot(named: "Plan grown into its list while streaming")
        try releaseDelta(2)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: deltaReady(3).path) }, timeout: 10), "The fixture should pause after the third plan delta.")
        assertStreamedProse(planOpening + [fullSecondParagraph] + (1...29).map(detail) + [
            "•\tFinal verification: confirm the latest message is visible after reopening",
            "Two numbered steps follow on the very next lines:",
            "1.\tFirst numbered step: capture the baseline state before changes.",
            "2.\tSecond numbered step: apply the fix and confirm there are no regressions.",
        ], stage: 3)
        XCTAssertTrue(waitUntil({ streamingCode.exists && streamingCode.value as? String == "console.log(\"Hello" }, timeout: 10),
                      "The code block should show the code streamed so far; shown=\(String(describing: streamingCode.value)).")
        try releaseDelta(3)
        // A long reply's label is a summary; its paragraphs carry the text.
        XCTAssertTrue(waitUntil({ self.transcriptContains("Final verification") }, timeout: 30), "The completed plan should replace the partial plan.")
        XCTAssertTrue(waitUntil({ streamingCode.exists && streamingCode.value as? String == "console.log(\"Hello, world!\");" }, timeout: 10),
                      "The completed code block should show all of its code; shown=\(String(describing: streamingCode.value)).")
        try FileManager.default.removeItem(at: deltaHold)
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Plan mode should stay selected after a planning response completes.")
        XCTAssertFalse(transcriptContains("<proposed_plan>"), "The plan should be shown automatically without its protocol wrapper.")
        XCTAssertFalse(transcriptContains("</proposed_plan>"), "The closing protocol wrapper should not be visible.")

        composer.click()
        composer.typeText("Revise the plan to clarify the persistence step.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
            )["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            let userIndex = history.firstIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Revise the plan to clarify the persistence step." }
            let finalIndex = history.lastIndex { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
            let fixtureData = try? Data(contentsOf: URL(fileURLWithPath: fixtureCopy.path + ".history"))
            let fixtureHistory = fixtureData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let turns = fixtureHistory?["turns"] as? [[String: Any]] ?? []
            return userIndex != nil && finalIndex != nil && finalIndex! > userIndex!
                && turns.last?["conversationMode"] as? String == "plan"
        }, timeout: 30), "A follow-up instruction should complete another plan turn.")
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "A follow-up plan should leave Plan mode enabled.")

        element("back-to-board-button").click()
        openTask(named: "Plan mode Markdown")
        XCTAssertTrue(element("conversation-mode-menu").label.contains("Plan mode"), "Reopening the task should preserve its planning mode.")
        let reloadedHistory = try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
        )["result"] as? [String: Any]
        let reloadedMessages = reloadedHistory?["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(reloadedMessages.contains { $0["role"] as? String == "assistant" && $0["text"] as? String == markdownReply }, "The exact Markdown source should persist after reopening the plan conversation.")
        XCTAssertEqual(reloadedMessages.last?["role"] as? String, "assistant", "The bridge history should keep the latest response last.")
        let planDiagnostics = try diagnosticEvents()
        let planSummary = try XCTUnwrap(planDiagnostics.first {
            $0["event"] as? String == "codex.notification.summary"
                && $0["method"] as? String == "item/plan/delta"
        })
        XCTAssertGreaterThanOrEqual(Int(planSummary["notificationCount"] as? String ?? "0") ?? 0, 2)
        XCTAssertGreaterThan(Int(planSummary["payloadBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertEqual(planSummary["flushReason"] as? String, "turn_completed")
        XCTAssertFalse(planDiagnostics.contains {
            $0["event"] as? String == "codex.notification" && $0["method"] as? String == "item/plan/delta"
        })
        let serializedPlanDiagnostics = String(data: try JSONSerialization.data(withJSONObject: planDiagnostics), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedPlanDiagnostics.contains(markdownReply), "Plan text must not be persisted in diagnostics.")
        // A long reply's label is a summary; its Markdown blocks carry the text.
        XCTAssertTrue(waitUntil({ self.transcriptContains("Implementation plan") }, timeout: 10), "The completed plan should appear automatically after reopening.")
        XCTAssertTrue(transcriptContains("Start with the workspace model.") && transcriptContains("A separate paragraph confirms readable spacing"),
                      "Both paragraphs should render after reopening.")
        XCTAssertFalse(transcriptContains("<proposed_plan>"), "The reloaded plan should hide its opening protocol wrapper.")
        XCTAssertFalse(transcriptContains("</proposed_plan>"), "The reloaded plan should hide its closing protocol wrapper.")
        let markdownContent = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Implementation plan")
        ).firstMatch
        XCTAssertTrue(markdownContent.waitToExist(timeout: 5), "The plan should render as one selectable Markdown text view.")
        let sharedProse = markdownContent.value as? String ?? ""
        for text in ["Start with the workspace model.", "A separate paragraph confirms readable spacing",
                     "Implementation detail 01", "Second numbered step"] {
            XCTAssertTrue(sharedProse.contains(text), "The heading, paragraphs, and list items should share one selectable text: \(text)")
        }
        XCTAssertFalse(sharedProse.contains("console.log"), "A fenced code block should stay in its own card.")
        // The shared text is taller than the viewport; click a line that is on screen.
        let visibleOrderedItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", "First numbered step"))
            .firstMatch
        XCTAssertTrue(visibleOrderedItem.waitToExist(timeout: 5))
        XCTAssertTrue(scrollFullyIntoView(visibleOrderedItem, in: element("conversation-scroll-view")))
        visibleOrderedItem.click()
        visibleOrderedItem.typeKey("a", modifierFlags: .command)
        visibleOrderedItem.typeKey("c", modifierFlags: .command)
        let copiedPlan = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedPlan.contains("Implementation plan"), "Selecting all should include the plan heading.")
        XCTAssertTrue(copiedPlan.contains("Implementation detail 01"), "Selecting all should include the first list item.")
        XCTAssertTrue(copiedPlan.contains("Implementation detail 15"), "Selecting all should include content from the middle of the plan.")
        XCTAssertTrue(copiedPlan.contains("Final verification: confirm the latest message is visible after reopening"), "Selecting all should include the final plan item.")
        XCTAssertTrue(copiedPlan.contains("First numbered step"), "Selecting all should include the first ordered list item.")
        XCTAssertTrue(copiedPlan.contains("Second numbered step"), "Selecting all should include the second ordered list item.")
        XCTAssertTrue(copiedPlan.contains("console.log"), "Selecting all should include the fenced code block's content.")

        let firstOrderedItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", "First numbered step"))
            .firstMatch
        XCTAssertTrue(firstOrderedItem.waitToExist(timeout: 5), "The first ordered list item should render as its own block.")
        XCTAssertFalse(firstOrderedItem.label.contains("Second numbered step"), "Ordered list items should stay on separate lines instead of being merged.")
        XCTAssertFalse(firstOrderedItem.label.contains("Two numbered steps follow"), "A list right under a paragraph line should not merge into that paragraph.")
        let secondOrderedItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", "Second numbered step"))
            .firstMatch
        XCTAssertTrue(secondOrderedItem.exists, "The second ordered list item should render as its own block.")

        // A list that starts at 2 after a heading renders as its own numbered items 2-5, keeping
        // its numbers, while a "3. 5 billion" line inside a paragraph stays prose.
        func orderedItem(_ text: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-markdown-ordered-list-item-", text))
                .firstMatch
        }
        let openQuestionTwo = orderedItem("Open question two")
        XCTAssertTrue(openQuestionTwo.waitToExist(timeout: 5), "A list starting at 2 should render as an ordered list.")
        _ = scrollFullyIntoView(openQuestionTwo, in: element("conversation-scroll-view"))
        for (number, word) in [(2, "two"), (3, "three"), (4, "four"), (5, "five")] {
            let item = orderedItem("Open question \(word)")
            XCTAssertTrue(item.waitToExist(timeout: 5), "Question \(number) should render as its own list item.")
            XCTAssertTrue(item.label.hasPrefix("\(number). "), "The list should keep its real numbers; label=\(item.label)")
            XCTAssertEqual(item.label.components(separatedBy: "Open question").count, 2, "Each list item should stay on its own line instead of merging with its neighbors.")
        }
        XCTAssertFalse(orderedItem("5 billion parameters").exists, "A '3. ' line inside a paragraph must stay prose, not a list item.")
        attachScreenshot(named: "Ordered list starting at 2 in the plan")

        let codeBlockLanguageLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-markdown-code-block-language-"))
            .firstMatch
        XCTAssertTrue(codeBlockLanguageLabel.waitToExist(timeout: 5), "The fenced code block should render with a visible language label.")
        XCTAssertEqual(accessibleLabelOrValue(of: codeBlockLanguageLabel), "Javascript", "The fenced code block's declared language should be displayed.")
        let codeBlockCopyButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-markdown-code-block-copy-"))
            .firstMatch
        XCTAssertTrue(codeBlockCopyButton.waitToExist(timeout: 5), "The fenced code block should render with a copy button.")
        codeBlockCopyButton.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "console.log(\"Hello, world!\");", "Copying the code block should place its exact source on the pasteboard, not the Markdown fence or surrounding prose.")

        let markdownTable = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "assistant-markdown-table-[0-9]+"))
            .firstMatch
        XCTAssertTrue(markdownTable.waitToExist(timeout: 5), "A Markdown pipe table should render as its own grid block.")
        func tableCell(_ suffix: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier MATCHES %@", "assistant-markdown-table-[0-9]+-\(suffix)"))
                .firstMatch
        }
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("header-0")), "Step", "The table's first column header should render in its own header cell.")
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("header-1")), "Status", "The table's second column header should render in its own header cell.")
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("cell-0-0")), "Verify fixture", "The table's first data row should render its cells in the matching columns.")
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("cell-0-1")), "Done", "The table's first data row should render its cells in the matching columns.")
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("cell-1-0")), "Render table", "The table's second data row should render its cells in the matching columns.")
        XCTAssertEqual(accessibleLabelOrValue(of: tableCell("cell-1-1")), "Pending", "The table's second data row should render its cells in the matching columns.")
        let longCell = tableCell("cell-2-1")
        let longCellText = accessibleLabelOrValue(of: longCell)
        XCTAssertTrue(longCellText.hasPrefix("This status note is deliberately long"), "The table's long cell should render in its own column.")
        // A cell's accessibility frame is its text's own frame, inside the cell's padding, so the
        // text measured at that width shows how tall the cell must be to show every line.
        let tableCellFont = NSFont.systemFont(ofSize: 14)
        func tableCellTextHeight(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: tableCellFont]).boundingRect(
                with: CGSize(width: longCell.frame.width + 1, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        }
        let longCellTextHeight = tableCellTextHeight(longCellText)
        XCTAssertGreaterThan(longCellTextHeight, tableCellTextHeight("Pending") * 2.5, "The long cell's text should need several lines at the rendered column width.")
        XCTAssertGreaterThanOrEqual(longCell.frame.height, longCellTextHeight - 1, "A long table cell should wrap onto every line its text needs instead of being cut off with an ellipsis.")
        XCTAssertFalse(transcriptContains("| Verify fixture |"), "The table's raw pipe source should not be shown as text.")
        XCTAssertFalse(transcriptContains("| --- |"), "The table's raw separator row should not be shown as text.")
        attachScreenshot(named: "Markdown table renders as a bordered grid")

        // The reply's last block is the closing paragraph after the table.
        let latestListItem = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@", "5 billion parameters"))
            .firstMatch
        // A reopened conversation opens at its newest question, not its end (the newest-messages
        // case covers that), so the paragraph is scrolled to rather than expected in view.
        XCTAssertTrue(scrollFullyIntoView(latestListItem, in: element("conversation-scroll-view")),
                      "The reply's closing paragraph should be reachable below the table.")
        let startImplementing = element("start-implementing-button")
        XCTAssertTrue(startImplementing.waitToExist(timeout: 5), "Plan mode should offer a dedicated implementation handoff.")
        XCTAssertEqual(element("message-composer").value as? String ?? "", "", "The handoff should be available while the composer is empty.")
        XCTAssertTrue(startImplementing.isEnabled, "Start Implementing should not require draft text.")
        XCTAssertFalse(element("start-implementing-unavailable-reason").exists, "A task with a working folder shows no missing-repository warning.")
        startImplementing.click()
        XCTAssertTrue(waitUntil({ element("conversation-mode-menu").label.contains("Code mode") }, timeout: 5), "Starting implementation should switch the composer to Code mode.")
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
            )["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            let userIndex = history.firstIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Start implementing the plan." }
            let finalIndex = history.lastIndex { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
            let fixtureData = try? Data(contentsOf: URL(fileURLWithPath: fixtureCopy.path + ".history"))
            let fixtureHistory = fixtureData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let turns = fixtureHistory?["turns"] as? [[String: Any]] ?? []
            return userIndex != nil && finalIndex != nil && finalIndex! > userIndex!
                && turns.last?["conversationMode"] as? String == "default"
        }, timeout: 30), "The handoff should start an implementation turn with the plan context.")
        attachScreenshot(named: "Plan mode stays active until implementation starts")
    }
    // case-contract: test_start_implementing_explains_missing_repository | A task with neither a repository nor a working folder can still plan, but once the plan exists its Start Implementing button is disabled and explains why: its tooltip and accessibility value read "Add a repository to this task to start implementing.", and a visible No repository warning beside it carries the same reason and opens the repository picker. Bridge state for the planned task has no workspace roots and no repository worktrees. Adding a repository gives the task a workspace root; in the still-open conversation the warning disappears and Start Implementing enables without reopening the task, then switches to Code mode and starts an implementation turn recorded after the plan turn, which runs in the task's created repository worktree as its only workspace root.
    func test_start_implementing_explains_missing_repository() throws {
        let executable = dataDirectory.appendingPathComponent("codex-fixture-plan-handoff-markdown")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: executable)
        codexFixtureExecutable = executable.path
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        let created = try runCLI(["task", "create", "--title", "Plan without repository", "--prompt", "Fixture task description."])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        func turnModes() -> [String] {
            let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
            let history = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (history?["turns"] as? [[String: Any]] ?? [])
                .filter { !(($0["userMessage"] as? String) ?? "").lowercased().contains("playhouse internal outcome nudge:") }
                .compactMap { $0["conversationMode"] as? String }
        }
        func conversationMessages() -> [[String: Any]] {
            (try? self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        }
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Plan without repository")

        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 10))
        modeMenu.click()
        let planMode = app.menuItems["Plan mode"]
        XCTAssertTrue(planMode.waitToExist(timeout: 5))
        planMode.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Plan the task.")
        element("send-message-button").click()

        let reason = "Add a repository to this task to start implementing."
        let startImplementing = element("start-implementing-button")
        let warning = element("start-implementing-unavailable-reason")
        XCTAssertTrue(startImplementing.waitToExist(timeout: 30), "Planning works without a repository, so the handoff appears once the plan turn ends.")
        XCTAssertTrue(waitUntil({
            conversationMessages().contains { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
        }, timeout: 30), "The plan turn completes without a repository or folder.")
        XCTAssertEqual(turnModes(), ["plan"], "The plan turn ran in Plan mode.")
        XCTAssertFalse(startImplementing.isEnabled, "Implementing needs somewhere to change, so the handoff stays disabled.")
        XCTAssertEqual(startImplementing.value as? String, reason, "The button's accessibility explains why it is unavailable.")
        XCTAssertTrue(warning.waitToExist(timeout: 5), "The reason is visible without hovering.")
        XCTAssertEqual(warning.label, "No repository")
        XCTAssertEqual(warning.value as? String, reason, "The warning carries the same reason as the button.")
        XCTAssertLessThan(abs(warning.frame.midY - startImplementing.frame.midY), 4, "The warning sits beside the button in the composer toolbar.")
        assertNativeHelpText(for: startImplementing, equals: reason)
        // The reason appears on screen only in the tooltip (the warning shows "No repository"),
        // so its disappearance shows the tooltip was dismissed.
        movePointerToHelpRunway(below: startImplementing)
        if !waitUntil({ !self.nativeHelpTextIsVisible(reason) }, timeout: 4) {
            movePointerToHelpRunway(below: startImplementing, horizontalShift: -60)
        }
        XCTAssertTrue(waitUntil({ !self.nativeHelpTextIsVisible(reason) }, timeout: 6), "Moving away dismisses the Start Implementing tooltip.")
        let task = try XCTUnwrap(try taskRecord(id: taskID))
        XCTAssertEqual((task["workspaceRoots"] as? [String]) ?? [], [], "The task has no workspace root to implement in.")
        XCTAssertEqual((task["repositoryWorktrees"] as? [[String: Any]])?.count ?? 0, 0)
        attachScreenshot(named: "Start Implementing explains the missing repository")

        // The warning is the way to fix it: it opens the header's repository picker.
        warning.click()
        XCTAssertTrue(element("conversation-repository-search").waitToExist(timeout: 5), "The warning opens the repository picker.")
        chooseRepositorySuggestion("primary")
        // The header picker adds the repository as the task's root; its worktree is named and
        // created by the next send, so the handoff below is what creates it.
        XCTAssertTrue(waitUntil({
            let record = try? self.taskRecord(id: taskID)
            let repositories = (record?["repositoryWorktrees"] as? [[String: Any]] ?? []).compactMap { $0["repositoryPath"] as? String }
            return repositories == [self.fixture.primary.path] && !(record?["workspaceRoots"] as? [String] ?? []).isEmpty
        }, timeout: 20), "Adding the repository gives the task a workspace root.")
        XCTAssertTrue(waitUntil({ !warning.exists && startImplementing.isEnabled }, timeout: 10), "The open conversation drops the warning and enables the handoff without reopening.")
        XCTAssertEqual(startImplementing.value as? String, "Available")
        attachScreenshot(named: "Start Implementing enabled once a repository is added")

        startImplementing.click()
        XCTAssertTrue(waitUntil({ modeMenu.label.contains("Code mode") }, timeout: 5), "Starting implementation switches the composer to Code mode.")
        XCTAssertTrue(waitUntil({
            // The fixture reuses one user item ID per thread, so the handoff's user item replaces
            // the plan's in history; the fixture's own turn log below records their order.
            let history = conversationMessages()
            let handoffIndex = history.firstIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Start implementing the plan." }
            let finalIndex = history.lastIndex { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
            return handoffIndex != nil && finalIndex != nil && finalIndex! > handoffIndex!
        }, timeout: 30), "The handoff starts an implementation turn that answers.")
        XCTAssertTrue(waitUntil({ turnModes() == ["plan", "default"] }, timeout: 30), "The handoff turn runs in Code mode after the plan turn.")
        // Paths are compared resolved, since /tmp fixtures can be reported through /private/tmp.
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        var lastRecord: [String: Any]?
        XCTAssertTrue(waitUntil({
            lastRecord = try? self.taskRecord(id: taskID)
            guard let record = lastRecord,
                  let worktree = (record["repositoryWorktrees"] as? [[String: Any]])?.first,
                  worktree["isPending"] as? Bool == false,
                  let path = worktree["worktreePath"] as? String,
                  resolved(path) != resolved(self.fixture.primary.path) else { return false }
            return (record["workspaceRoots"] as? [String] ?? []).map(resolved) == [resolved(path)]
        }, timeout: 20), "The implementation turn runs in the task's created worktree: \(String(describing: lastRecord?["repositoryWorktrees"])) roots \(String(describing: lastRecord?["workspaceRoots"]))")
    }
    // case-contract: test_thread_goal_lifecycle_persists_through_cli_xpc | CLI/XPC Goal set/get/pause/resume/clear persist the objective and lifecycle state across fresh connections and enable the Goals app-server feature; setting a first Goal on an Untitled task generates and persists its title from the objective before the Goal starts, while title failure uses the first eight objective words as fallback; setting the same active Goal preserves its timer generation, clearing then setting another Goal creates a new generation with a fresh baseline, setting a Goal moves the task to In Progress, and invalid blank objectives preserve the current Goal. The UI shows the generated title after reopening the task and restores saved Goals; the opt-in live Codex integration confirms native startup, verifies the first Goal retains its elapsed duration, restores a legacy completion without timing metadata, and confirms a second Goal timer begins near zero; renders each achieved summary as a conversation item that visibly moves with scrolling and is anchored to its completing turn, verifies a later user follow-up appears after the prior achievement through turn completion, and preserves both items and their ordering in the read-only Done archive. Native turn activation is owned by the retained GUI runtime.
    func test_thread_goal_lifecycle_persists_through_cli_xpc() throws {
        if isLiveCodexIntegration {
            codexFixtureExecutable = nil
        } else {
            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-goal-success").path
        }
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("codex-home"), withIntermediateDirectories: true)
        let usesLiveCodex = isLiveCodexIntegration
        if usesLiveCodex {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path), "Opt-in Goal verification requires an authenticated guest Codex home.")
        }
        launchApp(defaultParent: self.fixture.parent.path)
        let initialTaskTitle = usesLiveCodex ? "Durable goal" : "Untitled task"
        let displayedTaskTitle = usesLiveCodex ? initialTaskTitle : "Generated fixture title"
        try createTaskFixture(title: initialTaskTitle, roots: [self.fixture.primary.path])
        let taskID = try taskID(named: initialTaskTitle)
        let objective = "Write a short two-line song about a dog, mark this Goal complete, and finish the task with no follow-up needed."
        if !usesLiveCodex {
            _ = try runCLI(["conversation", "goal", taskID, "set", "--text", objective])
            _ = try runCLI(["conversation", "goal", taskID, "pause"])
        }
        openTask(named: displayedTaskTitle)
        if !usesLiveCodex {
            let title = element("task-view-title")
            XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: title) == displayedTaskTitle }, timeout: 10),
                          "The first Goal should generate and display the task title.")
            attachScreenshot(named: "First Codex Goal generates the task title")
            attachElementScreenshot(title, named: "Generated task title close up")
        }

        if !usesLiveCodex {
            let row = element("active-goal-progress-row")
            XCTAssertTrue(row.waitToExist(timeout: 10))
            let goalTitle = accessibleLabelOrValue(of: element("active-goal-title"))
            XCTAssertTrue(goalTitle.contains("Paused goal"), "Unexpected Goal title: \(goalTitle)")
            XCTAssertTrue(goalTitle.contains(objective), "Unexpected Goal objective: \(goalTitle)")
            let expandButton = element("goal-expand-button")
            expandButton.click()
            XCTAssertTrue(accessibleLabelOrValue(of: element("active-goal-details")).contains(objective))
            expandButton.click()

            let modeMenu = element("conversation-mode-menu")
            modeMenu.click()
            let goalMenuItem = app.menuItems["conversation-mode-goal"]
            goalMenuItem.click()
            XCTAssertTrue(modeMenu.label.contains("Goal"))
            element("send-message-button").click()
            XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 5))
            XCTAssertTrue(element("codex-chat-error").label.contains("4,000 characters"))
            XCTAssertTrue(accessibleLabelOrValue(of: element("active-goal-title")).contains(objective))
            XCTAssertTrue(accessibleLabelOrValue(of: element("active-goal-title")).contains("Paused goal"))

            let clearButton = element("goal-clear-button")
            clearButton.click()
            XCTAssertTrue(waitUntil({ !self.element("active-goal-progress-row").exists }, timeout: 5))
            app.terminate()
            let replacementObjective = "Write a short rhyme about a cat."
            _ = try runCLI(["conversation", "goal", taskID, "set", "--text", replacementObjective])
            _ = try runCLI(["conversation", "goal", taskID, "pause"])
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: displayedTaskTitle)
            let replacementRow = element("active-goal-progress-row")
            XCTAssertTrue(replacementRow.waitToExist(timeout: 10), "A replacement Goal should be restored after a CLI/XPC set.")
            XCTAssertTrue(accessibleLabelOrValue(of: element("active-goal-title")).contains(replacementObjective))
            let replacementTimer = element("goal-elapsed-time")
            XCTAssertTrue(replacementTimer.waitToExist(timeout: 10))
            let replacementTimerText = accessibleLabelOrValue(of: replacementTimer)
            let replacementSeconds = Int(replacementTimerText.replacingOccurrences(of: "s", with: ""))
            XCTAssertNotNil(replacementSeconds, "Expected a replacement Goal timer in seconds, got: \(replacementTimerText)")
            XCTAssertLessThanOrEqual(replacementSeconds ?? Int.max, 5, "A Goal created after clearing should not inherit the cleared Goal's time.")
            element("goal-clear-button").click()
            XCTAssertTrue(waitUntil({ !self.element("active-goal-progress-row").exists }, timeout: 5))
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: displayedTaskTitle)
            XCTAssertTrue(waitUntil({ !self.element("active-goal-progress-row").exists }, timeout: 10), "A cleared Goal must stay cleared after reopening the task.")
            return
        }

        let composer = element("message-composer")
        composer.click()
        composer.typeText("/goal")
        XCTAssertTrue(element("slash-command-goal").waitToExist(timeout: 5), "Typing /goal offers the command.")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "" }, timeout: 5), "Choosing /goal removes the typed command.")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitToExist(timeout: 5))
        XCTAssertTrue(modeMenu.label.contains("Goal"))
        element("send-message-button").click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 5), "Blank Goal text should show a validation error.")
        XCTAssertTrue(element("codex-chat-error").label.contains("4,000 characters"))
        XCTAssertTrue((try runCLI(["conversation", "goal", taskID, "get"])["result"] as? NSNull) != nil, "Blank Goal submission must not create an objective.")

        modeMenu.click()
        let goalMenuItem = app.menuItems["conversation-mode-goal"]
        goalMenuItem.click()
        XCTAssertTrue(modeMenu.label.contains("Goal"), "The composer menu should provide Goal mode.")
        composer.click()
        composer.typeText(objective)
        element("send-message-button").click()
        let row = element("active-goal-progress-row")
        XCTAssertTrue(row.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({
            self.element("goal-achieved-banner").exists
                || row.value as? String == "Work started"
                || row.value as? String == "Working"
        }, timeout: 30), "Submitting a Goal should start a Codex work turn, not only save the objective.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        let conversationScrollView = element("conversation-scroll-view")
        let achievedBanner = conversationScrollView.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(achievedBanner.waitToExist(timeout: 180), "Codex should replace the active Goal row with an achieved summary after completing the objective.")
        let firstAchievementText = accessibleLabelOrValue(of: achievedBanner)
        XCTAssertTrue(firstAchievementText.contains("Goal achieved in"))
        XCTAssertNotEqual(firstAchievementText, "Goal achieved in 0s", "A first Goal without prior usage should retain its reported elapsed duration.")
        XCTAssertTrue(element("goal-achievement-timeline-row").exists, "The achieved summary should be a conversation timeline event.")
        let assistantMessages = conversationScrollView.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-message-"))
        XCTAssertTrue(waitUntil({
            assistantMessages.count > 0
                && achievedBanner.frame.minY > assistantMessages.element(boundBy: assistantMessages.count - 1).frame.maxY
        }, timeout: 10), "The achievement event should follow the assistant response that completed its Goal.")
        let isolatedPreferences = try XCTUnwrap(UserDefaults(suiteName: preferencesSuiteName))
        [
            "playhouse.codex.goal-achievement-timeline.\(taskID)",
            "playhouse.codex.goal-generation.\(taskID)",
            "playhouse.codex.goal-generation-objective.\(taskID)",
            "playhouse.codex.goal-generation-time-baseline.\(taskID)",
        ].forEach { isolatedPreferences.removeObject(forKey: $0) }
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Durable goal")
        let migratedConversation = element("conversation-scroll-view")
        let migratedBanner = migratedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(migratedBanner.waitToExist(timeout: 10), "A completed Goal created before timing metadata existed should be reconstructed from Codex history.")
        XCTAssertNotEqual(
            accessibleLabelOrValue(of: migratedBanner),
            "Goal achieved in 0s",
            "Restoring an older completed Goal without generation metadata must retain its reported elapsed time."
        )
        XCTAssertFalse(row.exists, "Completed Goal state should not remain in the composer status row.")
        XCTAssertFalse(element("active-goal-title").exists)
        XCTAssertFalse(element("active-goal-details").exists)
        XCTAssertFalse(element("goal-expand-button").exists)
        XCTAssertFalse(element("goal-pause-resume-button").exists)
        XCTAssertFalse(element("goal-clear-button").exists)

        let followupPrompt = "Which two lines did you write? Please answer directly; after that, this task is complete and no follow-up is needed."
        composer.click()
        composer.typeText(followupPrompt)
        element("send-message-button").click()
        let followupMessage = conversationScrollView.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", followupPrompt)).firstMatch
        XCTAssertTrue(followupMessage.waitToExist(timeout: 10), "The follow-up question should appear in the conversation.")
        let achievementRow = conversationScrollView.descendants(matching: .any)
            .matching(identifier: "goal-achievement-timeline-row").firstMatch
        XCTAssertTrue(waitUntil({
            achievementRow.frame.maxY < followupMessage.frame.minY
        }, timeout: 10), "A follow-up message should scroll after the Goal achieved timeline item.")

        XCTAssertTrue(waitUntil({
            do {
                return try self.taskRecord(id: taskID)?["status"] as? String == "Review"
            } catch {
                return false
            }
        }, timeout: 180), "Codex should report the follow-up turn complete before the task enters the Done archive.")
        XCTAssertLessThan(
            achievementRow.frame.maxY,
            followupMessage.frame.minY,
            "The Goal achievement should stay before the follow-up after Codex finishes that turn."
        )

        let secondObjective = "Write a one-line rhyme about a cat, mark this Goal complete, and finish the task with no follow-up needed."
        composer.click()
        composer.typeText("/goal")
        XCTAssertTrue(element("slash-command-goal").waitToExist(timeout: 5))
        composer.typeKey(.return, modifierFlags: [])
        modeMenu.click()
        app.menuItems["conversation-mode-goal"].click()
        composer.click()
        composer.typeText(secondObjective)
        element("send-message-button").click()
        let secondGoalTimer = element("goal-elapsed-time")
        XCTAssertTrue(secondGoalTimer.waitToExist(timeout: 10), "A new Goal should show its own elapsed timer.")
        let secondGoalTimerText = accessibleLabelOrValue(of: secondGoalTimer)
        let secondGoalSeconds = Int(secondGoalTimerText.replacingOccurrences(of: "s", with: ""))
        XCTAssertNotNil(secondGoalSeconds, "Expected a fresh seconds timer, got: \(secondGoalTimerText)")
        XCTAssertLessThanOrEqual(secondGoalSeconds ?? Int.max, 5, "A new Goal timer must start near zero instead of carrying the previous Goal's duration.")
        let achievementRows = conversationScrollView.descendants(matching: .any)
            .matching(identifier: "goal-achievement-timeline-row")
        XCTAssertTrue(waitUntil({ achievementRows.count == 2 }, timeout: 180), "A second completed Goal should create its own timeline item.")
        let secondAchievementRow = achievementRows.element(boundBy: 1)
        XCTAssertTrue(waitUntil({
            followupMessage.frame.maxY < secondAchievementRow.frame.minY
        }, timeout: 10), "The second Goal achievement should be anchored after the intervening follow-up question.")
        XCTAssertTrue(waitUntil({
            assistantMessages.count > 0
                && secondAchievementRow.frame.minY > assistantMessages.element(boundBy: assistantMessages.count - 1).frame.maxY
        }, timeout: 10), "The second achievement event should follow the assistant response that completed its Goal.")
        XCTAssertTrue(waitUntil({
            do {
                return try self.taskRecord(id: taskID)?["status"] as? String == "Review"
            } catch {
                return false
            }
        }, timeout: 180), "Codex should report the second Goal complete before the task enters the Done archive.")
        let movedToDone = try runCLI(["task", "move", taskID, "Done"])["result"] as? [String: Any]
        XCTAssertEqual(movedToDone?["status"] as? String, "Done", "The Done transition should be accepted after Codex reports the task complete.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        element("back-to-board-button").click()
        let archiveButton = element("done-archive-button")
        XCTAssertTrue(archiveButton.waitToExist(timeout: 10))
        archiveButton.click()
        let archivedGoal = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archivedGoal.waitToExist(timeout: 10), "The completed Goal task should be available in the Done archive.")
        archivedGoal.click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        let reopenedConversation = element("conversation-scroll-view")
        let restoredBanner = reopenedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(restoredBanner.waitToExist(timeout: 10), "A completed Goal should remain visible in the archived conversation after archiving its task.")
        XCTAssertTrue(accessibleLabelOrValue(of: restoredBanner).contains("Goal achieved in"))
        let restoredAchievementRows = reopenedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achievement-timeline-row")
        XCTAssertEqual(restoredAchievementRows.count, 2, "Both completed Goal events should remain in the archived conversation.")
        XCTAssertTrue(reopenedConversation.scrollBars.firstMatch.waitToExist(timeout: 5), "The archived Goal transcript should expose scrolling when its conversation overflows.")
        let secondAchievementYBeforeScroll = restoredAchievementRows.element(boundBy: 1).frame.minY
        reopenedConversation.swipeDown()
        XCTAssertTrue(waitUntil({
            abs(restoredAchievementRows.element(boundBy: 1).frame.minY - secondAchievementYBeforeScroll) > 8
        }, timeout: 5), "Scrolling the conversation should move the Goal achievement with the transcript.")
        let restoredFollowup = reopenedConversation.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", followupPrompt)).firstMatch
        let restoredSecondAchievement = restoredAchievementRows.element(boundBy: 1)
        let restoredFirstAchievement = restoredAchievementRows.element(boundBy: 0)
        XCTAssertTrue(restoredFollowup.waitToExist(timeout: 10))
        for _ in 0..<8 where !waitUntil({
            restoredFirstAchievement.frame.maxY < restoredFollowup.frame.minY
        }, timeout: 1) {
            reopenedConversation.swipeDown()
        }
        XCTAssertTrue(waitUntil({
            restoredFirstAchievement.frame.maxY < restoredFollowup.frame.minY
        }, timeout: 10), "The first Goal achievement should remain before the follow-up in the archived conversation.")
        for _ in 0..<8 where !waitUntil({
            restoredFollowup.frame.maxY < restoredSecondAchievement.frame.minY
        }, timeout: 1) {
            reopenedConversation.swipeUp()
        }
        XCTAssertTrue(waitUntil({
            restoredFollowup.frame.maxY < restoredSecondAchievement.frame.minY
        }, timeout: 10), "The archived follow-up question should stay before the second Goal achievement.")
        XCTAssertFalse(element("active-goal-progress-row").exists)
        XCTAssertFalse(element("message-composer").exists)
        XCTAssertFalse(element("active-goal-title").exists)
        XCTAssertFalse(element("active-goal-details").exists)
        XCTAssertFalse(element("goal-expand-button").exists)
        XCTAssertFalse(element("goal-pause-resume-button").exists)
        XCTAssertFalse(element("goal-clear-button").exists)
    }
    // case-contract: test_codex_window_and_cli_share_one_app_server | A window and the CLI use one Codex app-server per Codex home. Every Codex request against one data folder (sends on two tasks, Goal set/get/pause/clear, history and usage refreshes, from the CLI and, in the UI, from an open window as well) runs on the same recorded server process, which listens on the shared unix socket with features.goals=true and the caller's CODEX_HOME and is the one live Codex manifest; it keeps running after every CLI Goal call, including a rejected blank objective, and a CLI call that spells the same CODEX_HOME differently reuses it. A send on the second task while the first task's Goal is active leaves that Goal active. The work turn Codex runs for the Goal is active and interruptible whether the window or the CLI set it; a history read during it, even with another model selected, never resumes the thread, and once pausing the Goal ends the turn, history resumes the thread with the selected model. A usage read the server never answers times out without stopping the server and keeps the last known Codex account, and the next refresh reads it again. In the UI, the window sets a Goal and follows the turn Codex starts for it, which stays active and interruptible while the CLI sends on the second task and ends when the window pauses the Goal; a Goal the CLI sets appears in the open window without reopening the task, the window's pause and clear reach the CLI's Goal reads, and the Agents info block shows the Codex account read through that server.
    func test_codex_window_and_cli_share_one_app_server() throws {
        let fixtureName = "codex-fixture-single-server-goal-success"
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent(fixtureName).path
        let stateDirectory = dataDirectory.appendingPathComponent("single-server-fixture-state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        codexFixtureStateDirectory = stateDirectory
        let codexHome = dataDirectory.appendingPathComponent("codex-home").path
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let launches = stateDirectory.appendingPathComponent("\(fixtureName).app-servers").path
        // The app-servers the fixture recorded: socket servers, and stdio launches that are not a
        // socket server's own stdio child.
        func recordedServers() -> [[String: Any]] {
            let records = jsonLines(launches).compactMap { $0 as? [String: Any] }
            let socketServers = Set(records.filter { ($0["listen"] as? String)?.hasPrefix("unix://") == true }.compactMap { $0["pid"] as? Int })
            return records.filter {
                ($0["listen"] as? String)?.hasPrefix("unix://") == true || !socketServers.contains($0["parentPID"] as? Int ?? -1)
            }
        }
        @discardableResult
        func assertOneLiveServer(_ context: String, pid expectedPID: Int? = nil) throws -> [String: Any] {
            let servers = recordedServers()
            XCTAssertEqual(servers.count, 1, "\(context): one app-server runs per Codex home, got \(servers)")
            let server = try XCTUnwrap(servers.first)
            let pid = try XCTUnwrap(server["pid"] as? Int)
            XCTAssertEqual(kill(pid_t(pid), 0), 0, "\(context): the shared app-server keeps running.")
            let live = agentManifests().filter { $0.kind == "codex" && agentIsAlive($0.manifest["process"] as? [String: Any]) }
            XCTAssertEqual(live.compactMap { (($0.manifest["process"] as? [String: Any])?["pid"] as? NSNumber)?.intValue }, [pid],
                           "\(context): the one live Codex manifest is the recorded server.")
            if let expectedPID { XCTAssertEqual(pid, expectedPID, "\(context): the same app-server serves the window and the CLI.") }
            return server
        }
        func cliGoal(_ arguments: [String], environment: [String: String] = [:]) throws -> [String: Any]? {
            try runCLI(["conversation", "goal"] + arguments, extraEnvironment: environment)["result"] as? [String: Any]
        }

        func runtimeState() throws -> [String: Any] {
            try XCTUnwrap(try runCLI(["conversation", "runtime"])["result"] as? [String: Any])
        }
        func codexUsage(_ environment: [String: String] = [:]) throws -> [String: Any]? {
            let providers = (try runCLI(["usage", "get", "--refresh"], extraEnvironment: environment)["result"] as? [String: Any])?["providers"] as? [[String: Any]]
            return providers?.first { $0["provider"] as? String == "codex" }
        }

        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Shared Codex server", "--prompt", Self.fixtureTaskPrompt, "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Shared Codex server")
        sendFromComposer("Hello from the window.")
        XCTAssertTrue(transcriptMessage("Hello from the window.").waitToExist(timeout: 15))
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 30), "The window's Codex turn should finish.")
        let server = try assertOneLiveServer("After the window's send")
        let pid = try XCTUnwrap(server["pid"] as? Int)
        XCTAssertTrue((server["listen"] as? String)?.hasPrefix("unix://") == true, "The shared app-server listens on its unix socket.")
        XCTAssertTrue((server["arguments"] as? [String])?.contains("features.goals=true") == true, "The one app-server always enables Codex Goals.")
        XCTAssertEqual(server["codexHome"] as? String, codexHome, "The app-server runs on the window's and the CLI's Codex home.")
        let threadID = try XCTUnwrap(try taskRecord(id: taskID)?["codexThreadID"] as? String)
        attachScreenshot(named: "shared-codex-server-1-window-turn")

        // The window sets a Goal and follows the turn Codex starts for it.
        let objective = "Keep the shared server running."
        let modeMenu = element("conversation-mode-menu")
        modeMenu.click()
        app.menuItems["conversation-mode-goal"].click()
        XCTAssertTrue(modeMenu.label.contains("Goal"))
        let composer = element("message-composer")
        composer.click()
        composer.typeText(objective)
        element("send-message-button").click()
        let row = element("active-goal-progress-row")
        XCTAssertTrue(row.waitToExist(timeout: 10))
        // The window shows the followed Goal turn running with its stop control.
        let goalWorking = { self.element("pause-response-button").exists }
        XCTAssertTrue(waitUntil(goalWorking, timeout: 30), "The window should follow the Goal's work turn.")
        XCTAssertEqual(try cliGoal([taskID, "get"])?["objective"] as? String, objective)
        try assertOneLiveServer("After the window's Goal set", pid: pid)

        // A CLI send on another task, on the same server, leaves the followed Goal turn running.
        let other = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Second Codex task", "--prompt", Self.fixtureTaskPrompt, "--root", fixture.primary.path, "--provider", "codex",
        ])["result"] as? [String: Any])
        let otherID = try XCTUnwrap(other["id"] as? String)
        XCTAssertEqual(try runCLI(["conversation", "send", otherID, "--message", "Hello from the second task."])["ok"] as? Bool, true)
        XCTAssertNotEqual(try taskRecord(id: otherID)?["codexThreadID"] as? String, threadID)
        let runtime = try runtimeState()
        XCTAssertTrue((runtime["activeThreadIDs"] as? [String] ?? []).contains(threadID), "The followed Goal turn stays active: \(runtime)")
        XCTAssertTrue((runtime["interruptibleThreadIDs"] as? [String] ?? []).contains(threadID), "The followed Goal turn stays interruptible: \(runtime)")
        XCTAssertTrue(goalWorking(), "The window still shows the Goal working.")
        try assertOneLiveServer("After a CLI send on the second task", pid: pid)
        // A history read meanwhile, even with another model selected, never resumes the thread
        // under the Goal's turn.
        let resumes = stateDirectory.appendingPathComponent("\(fixtureName).resumes").path
        let threadResumes = { self.jsonLines(resumes).compactMap { $0 as? [String: Any] }.filter { $0["threadId"] as? String == threadID } }
        XCTAssertEqual(try runCLI(["conversation", "model", taskID, "set", "gpt-6-sol"])["ok"] as? Bool, true)
        let resumedBefore = threadResumes().count
        XCTAssertTrue(try historyTexts(taskID: taskID).contains("Hello from the window."))
        XCTAssertEqual(threadResumes().count, resumedBefore, "A history read never resumes a thread under its running Goal turn.")
        XCTAssertTrue((try runtimeState()["interruptibleThreadIDs"] as? [String] ?? []).contains(threadID), "The Goal turn keeps running.")
        attachScreenshot(named: "shared-codex-server-2-window-goal-working-after-cli-send")

        // The window pauses the Goal, which ends its turn; the CLI reads it, and a rejected CLI set
        // leaves the server running.
        element("goal-pause-resume-button").click()
        XCTAssertTrue(waitUntil({ (try? cliGoal([taskID, "get"]))?["status"] as? String == "paused" }, timeout: 10),
                      "The window's pause should reach the CLI's Goal read.")
        XCTAssertTrue(waitUntil({ ((try? runtimeState())?["activeThreadIDs"] as? [String])?.contains(threadID) == false }, timeout: 10),
                      "Pausing the Goal ends the turn the window followed.")
        XCTAssertTrue(waitUntil({ !self.element("pause-response-button").exists }, timeout: 10), "The window shows the followed turn ending.")
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: self.element("active-goal-title")).contains("Paused goal") }, timeout: 10))
        let blank = try runCLI(["conversation", "goal", taskID, "set", "--text", "   "], expectedStatus: 2)
        XCTAssertEqual((blank["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        try assertOneLiveServer("After a window pause and a rejected CLI Goal set", pid: pid)
        attachScreenshot(named: "shared-codex-server-3-window-paused-goal")

        // CLI history, usage refreshes (one the server never answers) and a CLI call with
        // CODEX_HOME spelled differently use the same server.
        XCTAssertTrue(try historyTexts(taskID: taskID).contains("Hello from the window."))
        XCTAssertEqual(threadResumes().last?["model"] as? String, "gpt-6-sol", "Once the turn ends, history resumes the thread with the selected model.")
        XCTAssertEqual(try codexUsage()?["account"] as? String, "codex-fixture@example.com")
        let hang = stateDirectory.appendingPathComponent("\(fixtureName).account-read-hang").path
        touch(hang)
        let readStarted = Date()
        let timedOut = try codexUsage(["PLAYHOUSE_E2E_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS": "2"])
        XCTAssertLessThan(Date().timeIntervalSince(readStarted), 15, "An unanswered usage read gives up after its timeout.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hang), "The refresh asked the shared server for the account.")
        XCTAssertEqual(timedOut?["account"] as? String, "codex-fixture@example.com", "A timed-out read keeps the last known account.")
        try assertOneLiveServer("After an unanswered usage read", pid: pid)
        XCTAssertEqual(try codexUsage()?["account"] as? String, "codex-fixture@example.com", "The next refresh reads the account again.")
        XCTAssertEqual(try cliGoal([taskID, "get"], environment: ["CODEX_HOME": codexHome + "/."])?["status"] as? String, "paused")
        try assertOneLiveServer("After CLI history, usage refreshes and a respelled CODEX_HOME", pid: pid)

        // The window clears the Goal; the CLI reads that it is gone.
        element("goal-clear-button").click()
        XCTAssertTrue(waitUntil({ !row.exists }, timeout: 10))
        XCTAssertTrue(waitUntil({
            (try? self.runCLI(["conversation", "goal", taskID, "get"])).map { $0["ok"] as? Bool == true && !($0["result"] is [String: Any]) } == true
        }, timeout: 10), "The window's clear should reach the CLI's Goal read.")
        try assertOneLiveServer("After a window Goal clear", pid: pid)

        // A Goal the CLI sets on the shared server reaches the open window without reopening the task.
        let cliObjective = "Set from the command line."
        XCTAssertEqual(try cliGoal([taskID, "set", "--text", cliObjective])?["objective"] as? String, cliObjective)
        XCTAssertTrue(row.waitToExist(timeout: 10), "The open window should show the Goal the CLI set on the same app-server.")
        XCTAssertTrue(waitUntil({ accessibleLabelOrValue(of: self.element("active-goal-title")).contains(cliObjective) }, timeout: 10))
        try assertOneLiveServer("After a CLI Goal set", pid: pid)
        attachScreenshot(named: "shared-codex-server-4-cli-goal-in-window")
        XCTAssertNil(try cliGoal([taskID, "clear"]))
        XCTAssertTrue(waitUntil({ !row.exists }, timeout: 10), "The CLI's clear should reach the open window.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("agents-info-codex-account").waitToExist(timeout: 15))
        XCTAssertTrue(accessibleLabelOrValue(of: element("agents-info-codex-account")).contains("codex-fixture@example.com"),
                      "Agents info shows the Codex account read through the shared app-server.")
        try assertOneLiveServer("With the window and the CLI both done", pid: pid)
        attachScreenshot(named: "shared-codex-server-5-board-agents-info")
    }
}

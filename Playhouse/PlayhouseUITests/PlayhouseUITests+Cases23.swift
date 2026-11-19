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
    // case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions render inline, remain pending after switching to another conversation, and keep the task In Progress through fresh CLI/XPC history reconciliation after provider exit until answered. Free-text questions expose a selectable Other choice, select it when text is entered, keep it exclusive of listed answers, and deliver the free-text answer through CLI/XPC and visible UI. Answering resumes the provider turn without status nudges while its own pending question is still being resolved; the resumed turn returns to Waiting Response once the pending question clears, and the recovery prompt and response, including the secret answer, are stored and shown as sent.
    func test_codex_nonblocking_question_keeps_task_in_progress() throws {
        _ = try runCLI(["task", "create", "--title", "Non-blocking question", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        _ = try runCLI(["task", "create", "--title", "Another non-blocking conversation", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-nonblocking-restart-question").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Non-blocking question")
        element("message-composer").click()
        element("message-composer").typeText("Ask non-blocking questions.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-user-input-request").exists, "The non-blocking question should be inline, not presented in a modal.")
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "In Progress")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Non-blocking question", inColumn: "In Progress")
        openTask(named: "Another non-blocking conversation")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 5))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Non-blocking question", inColumn: "In Progress")
        openTask(named: "Non-blocking question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 5), "Returning should restore the pending question inline.")
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "In Progress")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Non-blocking question", inColumn: "In Progress")
        openTask(named: "Non-blocking question")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 5))
        let otherOption = app.buttons["Other"]
        XCTAssertTrue(otherOption.exists, "An allowed free-text answer must have an explicit Other radio choice.")
        otherOption.click()
        XCTAssertEqual(otherOption.value as? String, "selected")
        let blueOption = element("ai-question-option-color-Blue")
        blueOption.click()
        XCTAssertEqual(blueOption.value as? String, "selected", "Selecting a listed choice must replace Other.")
        XCTAssertEqual(otherOption.value as? String, "not selected")
        let otherAnswer = app.textFields["Other answer"]
        otherAnswer.click()
        otherAnswer.typeText("Custom approach")
        XCTAssertEqual(otherOption.value as? String, "selected", "Typing an Other answer must select the Other choice.")
        XCTAssertEqual(blueOption.value as? String, "not selected", "Typing an Other answer must clear listed choices.")
        let secretAnswer = element("ai-question-answer-token")
        secretAnswer.click()
        secretAnswer.typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        let nonblockingDeadline = Date().addingTimeInterval(5)
        var nonblockingStatus: String?
        while Date() < nonblockingDeadline {
            nonblockingStatus = try taskRecord(named: "Non-blocking question")?["status"] as? String
            if nonblockingStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(nonblockingStatus, "In Progress", "A non-blocking recovery answer should leave the task active until the resumed turn completes.")
        // The recovered turn and the prompt that carried its answers are shown as sent, as in CLI/XPC history.
        XCTAssertTrue(transcriptMessage("Answers received: Custom approach / fixture-secret.").waitToExist(timeout: 10))
        XCTAssertTrue(transcriptContains("Answer: Custom approach"), "The prompt that carried the answers is shown as sent.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(named: "Non-blocking question")?["status"] as? String) == "Waiting Response" }, timeout: 20))
        let fixturePath = try XCTUnwrap(codexFixtureExecutable)
        let fixtureHistoryData = try Data(contentsOf: URL(fileURLWithPath: fixturePath + ".history"))
        let fixtureHistory = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureHistoryData) as? [String: Any])
        let fixtureTurns = try XCTUnwrap(fixtureHistory["turns"] as? [[String: Any]])
        let reminders = fixtureTurns.filter { ($0["userMessage"] as? String)?.contains("Playhouse internal outcome nudge:") == true }
        XCTAssertEqual(reminders.count, 0, "A pending question still being resolved during the recovered turn must suppress private outcome reminders.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playhouse internal outcome nudge:")).firstMatch.exists)
        XCTAssertFalse(element("conversation-user-input-request").exists)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        assertTaskVisible("Non-blocking question", inColumn: "Waiting Response")
    }
    // case-contract: test_codex_async_questions_render_and_reply_as_followup | Async agentMessage questions retain choices and a free-text prompt in live updates and fresh CLI/XPC history, retain accepted-turn model attribution during an active history reload, stay separate from later assistant text, and receive validated answers through the shared manager during and after an active turn. The UI shows inline answer cards instead of raw bullet text, blocks incomplete answers, preserves answered cards across reopening, and displays both submitted answers and responses.
    func test_codex_async_questions_render_and_reply_as_followup() throws {
        let created = try runCLI(["task", "create", "--title", "Async Codex question", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Async Codex question")
        element("message-composer").click()
        element("message-composer").typeText("Ask an async question.")
        element("send-message-button").click()

        let card = element("async-question-item_playhouse_async_question")
        XCTAssertTrue(card.waitToExist(timeout: 10))
        let yesOption = element("async-question-option-item_playhouse_async_question-0-0")
        let noOption = element("async-question-option-item_playhouse_async_question-0-1")
        XCTAssertEqual(yesOption.label, "Yes, update paired tests and run required verification")
        XCTAssertEqual(noOption.label, "No, leave tests and verification for later")
        XCTAssertTrue(element("async-question-answer-item_playhouse_async_question-1").exists)
        XCTAssertFalse(element("assistant-message-item_playhouse_async_question").exists,
                       "Structured choices should appear in an answer card instead of a Markdown bubble.")
        XCTAssertFalse(element("submit-async-questions-item_playhouse_async_question").isEnabled)
        XCTAssertTrue(app.staticTexts["I can continue while you decide."].waitToExist(timeout: 10),
                      "The assistant message after the question must remain separate.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question.question-ready").path),
                      "The question fixture must still have an active turn.")
        element("back-to-board-button").click()
        openTask(named: "Async Codex question")
        XCTAssertTrue(app.staticTexts["I can continue while you decide."].waitToExist(timeout: 10),
                      "Reopening during the active turn must load Codex history, not only restore the pending question request.")
        XCTAssertTrue(app.staticTexts["Codex · Luna"].exists,
                      "The reopened active history message must retain its accepted-turn model label.")
        XCTAssertTrue(element("async-question-item_playhouse_async_question").exists,
                      "The pending question remains visible after the active history reload.")
        XCTAssertEqual(yesOption.value as? String, "not selected", "No async option is chosen before the click.")
        selectQuestionOption(yesOption, named: "async Yes option", file: #filePath, line: #line)
        XCTAssertEqual(noOption.value as? String, "not selected", "Choosing one async option leaves the other unselected.")
        XCTAssertFalse(element("submit-async-questions-item_playhouse_async_question").isEnabled,
                       "Every async question needs an answer before submission.")
        let detail = element("async-question-answer-item_playhouse_async_question-1")
        detail.click()
        detail.typeText("Keep the draft intact.")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("An unsent draft stays here.")
        element("submit-async-questions-item_playhouse_async_question").click()

        XCTAssertTrue(waitUntil({ self.transcriptContains("Additional detail: Keep the draft intact.") }, timeout: 10), "The full two-answer reply must be sent.")
        // Playhouse names stored messages after its own turns, so find the steered answer by content.
        let response = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-",
            "Answers received: Test and verify: Yes, update paired tests and run required verification"
        )).firstMatch
        // Playhouse's outcome nudge can follow at once and push the reply out of the rendered rows.
        XCTAssertTrue(response.waitToExist(timeout: 10) || transcriptScan { response.exists }, "The steered answer should be in the transcript.")
        XCTAssertTrue(response.label.contains("Answers received: Test and verify: Yes, update paired tests and run required verification"))
        XCTAssertTrue(response.label.contains("Additional detail: Keep the draft intact."))
        XCTAssertTrue(transcriptScan { card.exists && card.staticTexts["Answered"].exists }, "The answered card should stay in the transcript.")
        XCTAssertEqual(composer.value as? String, "An unsent draft stays here.")
        let laterCard = element("async-question-item_playhouse_async_later_question")
        XCTAssertTrue(laterCard.waitToExist(timeout: 10) || transcriptScan { laterCard.exists }, "The later question should be in the transcript.")
        // The unsent draft shows Send in Stop's place while the turn runs, so wait on the runtime.
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "The later answer must be submitted after the first turn completes.")
        let laterAnswer = element("async-question-answer-item_playhouse_async_later_question-0")
        // Later replies below the card can carry its field out of view; bring it back before typing.
        XCTAssertTrue(revealInConversation(laterAnswer), "The later question's answer field should scroll into view.")
        laterAnswer.click()
        laterAnswer.typeText("Finish after the turn.")
        element("submit-async-questions-item_playhouse_async_later_question").click()
        // Stored replies carry Playhouse's own turn IDs, so match the reply by its answer.
        let completedResponse = app.groups.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Answers received: One more check: Finish after the turn."
        )).firstMatch
        XCTAssertTrue(completedResponse.waitToExist(timeout: 10),
                      "A question answered after its original turn must refresh the visible conversation.")
        XCTAssertTrue(completedResponse.label.contains("Answers received: One more check: Finish after the turn."))
        XCTAssertEqual(composer.value as? String, "An unsent draft stays here.")
        element("back-to-board-button").click()
        openTask(named: "Async Codex question")
        XCTAssertTrue(revealWholeTranscript(), "The reopened conversation should load its earlier turns as the reader scrolls up.")
        // Earlier rows render only near the viewport, so each card is found by scanning the transcript.
        XCTAssertTrue(transcriptScan { card.exists && card.staticTexts["Answered"].exists }, "The first question must stay answered after reopening.")
        XCTAssertTrue(transcriptScan { laterCard.exists && laterCard.staticTexts["Answered"].exists }, "The later question must stay answered after reopening.")
        XCTAssertEqual(element("message-composer").value as? String, "An unsent draft stays here.")
    }
    // case-contract: test_codex_async_question_queued_answer_retries | An async question answered after its turn ends stays Pending when the first follow-up fails, rejects duplicate answers across fresh CLI/XPC connections, and becomes Answered only after an explicit queued retry succeeds. The paired UI keeps the card and queue action visible across reopening and then displays the delivered response. A fresh `conversation answered-async` read lists no answered questions while the answer is pending and lists the question once it is delivered. The failed answer is not kept in the conversation as a sent message, and the retry sends it exactly once.
    func test_codex_async_question_queued_answer_retries() throws {
        let created = try runCLI(["task", "create", "--title", "Queued async question", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question-queued")
        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Queued async question")
        element("message-composer").click()
        element("message-composer").typeText("Ask a queued async question.")
        element("send-message-button").click()
        let card = element("async-question-item_playhouse_async_question")
        XCTAssertTrue(card.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID))?["status"] as? String) == "Waiting Response"
        }, timeout: 10), "The first turn must finish before queueing the answer.")
        _ = FileManager.default.createFile(atPath: executable.path + ".fail-next-turn-start", contents: Data())
        // The transcript reloads as the turn ends, so wait for the option to settle and confirm the
        // click chose it; a click that lands on the neighbouring option would queue the wrong answer.
        selectQuestionOption(identifier: "async-question-option-item_playhouse_async_question-0-0")
        element("async-question-answer-item_playhouse_async_question-1").click()
        element("async-question-answer-item_playhouse_async_question-1").typeText("Retry this answer.")
        element("submit-async-questions-item_playhouse_async_question").click()
        XCTAssertTrue(card.staticTexts["Pending"].waitToExist(timeout: 10))
        let queueResult = try runCLI(["conversation", "queue-list", taskID])
        let queued = try XCTUnwrap((queueResult["result"] as? [[String: Any]])?.first)
        XCTAssertEqual(queued["asyncQuestionItemID"] as? String, "item_playhouse_async_question")
        let queuedID = try XCTUnwrap(queued["id"] as? String)
        XCTAssertEqual(queued["state"] as? String, "needsAction")
        let pendingAnswered = try XCTUnwrap(try runCLI(["conversation", "answered-async", taskID])["result"] as? [String: Any])
        XCTAssertEqual(pendingAnswered["itemIDs"] as? [String], [], "A pending async answer is not answered yet.")
        let queuedReply = "Test and verify: Yes, update paired tests and run required verification\nAdditional detail: Retry this answer."
        let pendingMessages = (try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(pendingMessages.contains { $0["role"] as? String == "user" && $0["text"] as? String == queuedReply },
                       "The answer stays in the queue as needs-action, so the conversation doesn't show it as sent.")
        element("back-to-board-button").click()
        openTask(named: "Queued async question")
        XCTAssertTrue(transcriptScan { card.exists && card.staticTexts["Pending"].exists }, "The answered question stays Pending after reopening.")
        // The answer's text stays on its card and queued row; only a sent bubble would claim it reached Codex.
        let sentAnswerBubbles = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "user-message-", "Additional detail: Retry this answer."
        ))
        assertTranscriptLacks("The pending answer is not shown as a sent message.") { sentAnswerBubbles.count > 0 }
        let retry = element("retry-queued-message-\(queuedID.uppercased())")
        XCTAssertTrue(retry.waitToExist(timeout: 5))
        // The scans end at the bottom; bring the Pending card back into view for the screenshot.
        XCTAssertTrue(transcriptScan { card.exists && card.isHittable }, "The Pending card can be shown beside its retry action.")
        attachScreenshot(named: "Queued async answer pending with its retry action")
        retry.click()
        // Playhouse names stored messages after its own turns, so find the answer by content.
        let response = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Answers received: Test and verify"))
            .firstMatch
        XCTAssertTrue(response.waitToExist(timeout: 10))
        XCTAssertTrue(response.label.contains("Answers received: Test and verify: Yes, update paired tests and run required verification"))
        XCTAssertTrue(response.label.contains("Additional detail: Retry this answer."))
        // The response and the outcome nudge can push the card out of the lazy viewport, so scan for it.
        XCTAssertTrue(waitUntil({ self.transcriptScan { card.exists && card.staticTexts["Answered"].exists } }, timeout: 10),
                      "The queued answer should settle as Answered after its response appears.")
        let deliveredAnswered = try XCTUnwrap(try runCLI(["conversation", "answered-async", taskID])["result"] as? [String: Any])
        XCTAssertEqual(deliveredAnswered["itemIDs"] as? [String], ["item_playhouse_async_question"], "The delivered async answer should be recorded as answered.")
        XCTAssertTrue(transcriptScan { sentAnswerBubbles.count > 0 }, "The retried answer shows as sent.")
        assertTranscriptLacks("The retried answer shows as sent once, not twice.") { sentAnswerBubbles.count > 1 }
        attachScreenshot(named: "Queued async answer delivered once and answered")
        let deliveredMessages = (try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(deliveredMessages.filter { $0["role"] as? String == "user" && $0["text"] as? String == queuedReply }.count, 1,
                       "The retried answer is sent once.")
    }
    // case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; a genuine interrupted outcome remains Blocked with its reason, while restart recovery returns stale In Progress work to Waiting Response with its prompt and conversation available. A saved prompt whose turn never started returns to Waiting Response with its draft intact and can be continued; a turn running when the window quits cleanly or is killed keeps running in the bridge daemon, stays In Progress with its prompt visible after relaunch, finishes, and allows a follow-up. Interrupted outcomes and diagnostics persist across connections; a new prompt can finish in Review. The live turn's activity section renders open and folds away when the interrupted turn settles without an answer, on the conversation that stayed open; the interrupted turn adds no final answer and keeps the activity it reported. A queued follow-up remains visible as needing action after interruption, survives reopening, and is dispatched only after an explicit retry; the completed retry becomes the task's latest saved prompt. Recovering a never-started turn into Waiting Response starts Ping once.
    func test_codex_interrupted_turn_blocks_with_reason_and_can_retry() throws {
        _ = try runCLI(["task", "create", "--title", "Interrupted turn", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-interrupted").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Interrupted turn")
        element("message-composer").click()
        element("message-composer").typeText("Start work that will be interrupted.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        let interruptedActivity = element("codex-activity-disclosure")
        XCTAssertTrue(interruptedActivity.waitToExist(timeout: 10), "A live turn should surface its activity section.")
        XCTAssertTrue(waitUntil({ interruptedActivity.value as? String == "Expanded, down chevron" }, timeout: 10),
                      "A turn in flight should show its work instead of hiding it behind Working for.")
        // The lone reported activity is still running, so it occupies the live slot
        // outside the section; the open section itself has nothing inside it yet.
        XCTAssertTrue(element("codex-activity-row-item_fixture_interrupted_command").waitToExist(timeout: 10),
                      "The live turn should render its reported activity without a click.")
        let interruptedID = try taskID(named: "Interrupted turn")
        let queuedText = "Follow up after I review the interrupted turn."
        let queued = try runCLI(["conversation", "queue", interruptedID, "--message", queuedText])["result"] as? [String: Any]
        let queuedID = try XCTUnwrap(queued?["id"] as? String)
        // The queued follow-up bar shortens the transcript; answer once it is in place.
        // The bar's container is not an accessibility element of its own; its Steer button is.
        XCTAssertTrue(element("steer-queued-message-\(queuedID.uppercased())").waitToExist(timeout: 10), "The queued follow-up should show above the composer.")
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()

        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10))
        // The turn settles with no answer. Its reported activity keeps the section
        // mounted on the same conversation, so it must be folded rather than gone:
        // asserting the section still exists is what makes the collapse meaningful.
        XCTAssertTrue(waitUntil({ interruptedActivity.value as? String == "Collapsed, right chevron" }, timeout: 10),
                      "An interrupted turn should fold its activity section away instead of resting open.")
        XCTAssertTrue(interruptedActivity.exists, "The interrupted turn's activity section should stay available, just folded.")
        XCTAssertFalse(element("codex-activity-details").exists, "A settled interrupted turn should not rest on expanded activity details.")
        XCTAssertFalse(element("pause-response-button").exists, "The interrupted turn should no longer be responding.")
        attachScreenshot(named: "Activity folds away when an interrupted turn settles")
        XCTAssertTrue(app.staticTexts["Follow-up needs your action"].waitToExist(timeout: 10), "An interrupted turn must retain its queued message for an explicit retry.")
        let blocked = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(blocked["status"] as? String, "Blocked")
        XCTAssertTrue((blocked["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)
        let sendFailure = try XCTUnwrap(diagnosticEvents().first {
            $0["event"] as? String == "conversation.send.failed" && $0["taskID"] as? String == interruptedID
        })
        XCTAssertEqual(sendFailure["phase"] as? String, "codex-turn")
        XCTAssertEqual(sendFailure["storePath"] as? String, dataDirectory.appendingPathComponent("Playhouse-v2.store").path)

        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        app.launchEnvironment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        openTask(named: "Interrupted turn")
        let reopened = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(reopened["status"] as? String, "Blocked")
        XCTAssertTrue((reopened["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Interrupted turn", prompt: "Retry the interrupted task.")
        XCTAssertEqual(try taskRecord(named: "Interrupted turn")?["status"] as? String, "Review")
        let retryQueuedButton = element("retry-queued-message-\(queuedID.uppercased())")
        XCTAssertTrue(retryQueuedButton.waitToExist(timeout: 10), "The retained follow-up should remain explicitly retryable after reopening and completing a new turn.")
        retryQueuedButton.click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10), "Explicit retry should submit the queued message to Codex.")
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({
            (((try? self.runCLI(["conversation", "queue-list", interruptedID])["result"] as? [[String: Any]]) ?? [])).isEmpty
        }, timeout: 10), "A completed explicit retry should remove the queued item.")
        XCTAssertEqual(try taskRecord(id: interruptedID)?["savedPrompt"] as? String, queuedText, "The successfully retried follow-up should become the latest saved prompt.")

        _ = try runCLI(["task", "create", "--title", "Reopen active turn", "--prompt", "Fixture task description.", "--root", fixture.primary.path])
        let cleanRestartFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold").path
        codexFixtureExecutable = cleanRestartFixtureExecutable
        try? FileManager.default.removeItem(atPath: cleanRestartFixtureExecutable + ".hold-used")
        app.launchEnvironment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = cleanRestartFixtureExecutable
        relaunchApp()
        openTask(named: "Reopen active turn")
        element("message-composer").click()
        element("message-composer").typeText("Leave this turn active while Playhouse closes.")
        element("send-message-button").click()
        let activeDeadline = Date().addingTimeInterval(10)
        var activeStatus: String?
        while Date() < activeDeadline {
            activeStatus = try taskRecord(named: "Reopen active turn")?["status"] as? String
            if activeStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(activeStatus, "In Progress")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: cleanRestartFixtureExecutable + ".hold-used") }, timeout: 10), "Codex should reach the deliberate held turn before the app closes.")
        attachScreenshot(named: "Task remains In Progress while the Codex turn is active")

        relaunchApp()
        openTask(named: "Reopen active turn")
        // The bridge daemon owns the turn, so quitting the window leaves it running.
        XCTAssertEqual(try taskRecord(named: "Reopen active turn")?["status"] as? String, "In Progress", "A clean quit should leave the daemon-owned turn running.")
        XCTAssertTrue(transcriptMessage("Leave this turn active while Playhouse closes.").waitToExist(timeout: 10), "The visible transcript should restore the prompt after a clean quit.")
        XCTAssertTrue(app.staticTexts["In Progress"].waitToExist(timeout: 10), "The reopened window should show the still-running turn.")
        let interruptedHistory = try runCLI(["conversation", "history", try taskID(named: "Reopen active turn")])["result"] as? [String: Any]
        XCTAssertTrue(
            ((interruptedHistory?["messages"] as? [[String: Any]]) ?? []).contains {
                $0["role"] as? String == "user" && $0["text"] as? String == "Leave this turn active while Playhouse closes."
            },
            "The running turn's prompt should be in the saved conversation after a clean quit."
        )
        try Data("Finish the turn that outlived the window.\n".utf8).write(to: URL(fileURLWithPath: cleanRestartFixtureExecutable + ".turn-release"), options: .atomic)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(named: "Reopen active turn")?["status"] as? String) != "In Progress" }, timeout: 15), "The turn that outlived the window should finish.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").exists }, timeout: 10), "The reopened window should follow the finished turn.")
        try completeCurrentTaskWithFixtureAnswers(
            taskTitle: "Reopen active turn",
            prompt: "Continue the saved work after relaunch.",
            reportCompletedOutcome: false
        )
        XCTAssertEqual(try taskRecord(named: "Reopen active turn")?["status"] as? String, "Waiting Response")
        attachScreenshot(named: "Playhouse resumes the saved conversation after a clean quit")

        let neverStarted = try XCTUnwrap(try runCLI(["task", "create", "--title", "Never started recovery", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])
        let neverStartedID = try XCTUnwrap(neverStarted["id"] as? String)
        _ = try runCLI(["task", "prompt", neverStartedID, "--text", "Recover this prompt", "--status", "In Progress", "--submitted", "true"])
        element("back-to-board-button").click()
        openTask(named: "Never started recovery")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: neverStartedID)?["status"] as? String) == "Waiting Response" }, timeout: 15))
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String)?.contains("Recover this prompt") == true }, timeout: 15), "A prompt whose turn never started should return to the composer.")
        XCTAssertFalse(transcriptMessage("Recover this prompt").exists, "A never-started prompt returns as a draft, not as a sent message.")
        XCTAssertFalse(element("pause-response-button").exists, "A recovered never-started prompt leaves no turn running.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").isEnabled }, timeout: 5), "A recovered never-started prompt can be continued.")
        XCTAssertEqual(try diagnosticEvents().filter { $0["event"] as? String == "task.status_sound.played" && $0["taskID"] as? String == neverStartedID }.compactMap { $0["sound"] as? String }, ["Ping"])
        element("back-to-board-button").click()

        let unexpectedTask = try XCTUnwrap(
            (try runCLI(["task", "create", "--title", "Unexpected restart", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])
        )
        let unexpectedTaskID = try XCTUnwrap(unexpectedTask["id"] as? String)
        let unexpectedRestartFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold").path
        codexFixtureExecutable = unexpectedRestartFixtureExecutable
        try? FileManager.default.removeItem(atPath: unexpectedRestartFixtureExecutable + ".hold-used")
        app.launchEnvironment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = unexpectedRestartFixtureExecutable
        relaunchApp()
        openTask(named: "Unexpected restart")
        let unexpectedPrompt = "Keep this work available after an unexpected restart."
        element("message-composer").click()
        element("message-composer").typeText(unexpectedPrompt)
        element("send-message-button").click()
        let unexpectedDeadline = Date().addingTimeInterval(10)
        var unexpectedStatus: String?
        while Date() < unexpectedDeadline {
            unexpectedStatus = try taskRecord(id: unexpectedTaskID)?["status"] as? String
            if unexpectedStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(unexpectedStatus, "In Progress")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: unexpectedRestartFixtureExecutable + ".hold-used") }, timeout: 10), "Codex should reach the deliberate held turn before simulated process loss.")
        let appBundleIdentifier = try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier)
        let appProcessID = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).first,
            "The app process should be visible before simulating unexpected termination."
        ).processIdentifier
        XCTAssertGreaterThan(appProcessID, 0)
        XCTAssertEqual(Darwin.kill(appProcessID, SIGKILL), 0, "The fixture app should be terminated without running its quit cleanup.")
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 10), "Playhouse should stop after the simulated unexpected termination.")

        launchAppWithOpen()
        waitForBoardOrAbortSuite()
        openTask(named: "Unexpected restart")
        XCTAssertEqual(try taskRecord(id: unexpectedTaskID)?["status"] as? String, "In Progress", "The daemon-owned turn should survive the window's unexpected termination.")
        XCTAssertTrue(transcriptMessage(unexpectedPrompt).waitToExist(timeout: 10), "The visible transcript should restore the prompt after unexpected termination.")
        let unexpectedHistory = try runCLI(["conversation", "history", unexpectedTaskID])["result"] as? [String: Any]
        XCTAssertTrue(
            ((unexpectedHistory?["messages"] as? [[String: Any]]) ?? []).contains {
                $0["role"] as? String == "user" && $0["text"] as? String == unexpectedPrompt
            },
            "The unexpected restart should preserve the last submitted message in conversation history."
        )
        let survivingTurnRelease = URL(fileURLWithPath: unexpectedRestartFixtureExecutable + ".turn-release")
        try Data("Finish the turn that survived the window.\n".utf8).write(to: survivingTurnRelease, options: .atomic)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: unexpectedTaskID)?["status"] as? String) != "In Progress" }, timeout: 15), "The turn that survived the window should finish.")
        XCTAssertTrue(waitUntil({ self.element("send-message-button").exists }, timeout: 10))
        try completeCurrentTaskWithFixtureAnswers(
            taskTitle: "Unexpected restart",
            prompt: "Continue after an unexpected restart.",
            reportCompletedOutcome: false
        )
        XCTAssertEqual(try taskRecord(id: unexpectedTaskID)?["status"] as? String, "Waiting Response")
        attachScreenshot(named: "Playhouse recovers and continues work after an unexpected restart")
    }
    // case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view lists every file changed from the task branch's recorded base in a Changes section below a collapsed Viewed section, including committed branch changes and current staged, unstaged, and untracked edits, and excluding commits unique to the base branch. Marking a file viewed saves its current contents, stages the file in Git, and adds a Viewed entry that keeps showing the reviewed work from the branch base to that snapshot. Work done after that review is listed again under Changes and diffed against the saved snapshot, so one file can appear in both sections at once; a path with no content in the branch base and no current file is zero net change and is hidden entirely, even with a stale viewed snapshot, rather than showing a ghost entry. Selecting text or JSON files opens a calculated side-by-side diff whose header names the baseline used. Viewed snapshots persist across fresh CLI/XPC connections. Files that aren't current Changes entries, including already-viewed and unknown paths, are rejected by the mark-viewed CLI operation, and the UI offers that action only for Changes entries. Uncommitted filenames are green. Opening one diff after another serves each file's own content from the side-by-side editor the app loads once per session, so a later diff reuses that warm editor instead of starting Monaco again. Diagnostics record inventory and file-read outcomes without logging file contents.
    func test_task_workspace_changes_group_staged_and_unstaged_diffs() throws {
        _ = try runCLI([
            "task", "create", "--title", "Git changes", "--prompt", "Fixture task description.", "--root", fixture.changes.path
        ])
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Git changes")

        XCTAssertTrue(element("unviewed-changes-section").waitToExist(timeout: 10))
        assertText("unviewed-changes-title", equals: "Changes")
        assertText("viewed-changes-title", equals: "Viewed")
        XCTAssertTrue(element("viewed-changes-section").exists)
        XCTAssertLessThan(element("viewed-changes-section").frame.minY, element("unviewed-changes-section").frame.minY)
        XCTAssertTrue(element("workspace-change-unviewed-shared.txt").exists)
        XCTAssertTrue(element("workspace-change-unviewed-untracked.txt").exists)
        XCTAssertTrue(element("workspace-change-unviewed-deleted.txt").exists)
        XCTAssertTrue(element("workspace-change-unviewed-syntax.json").exists)
        XCTAssertTrue(element("mark-viewed-shared.txt").exists)
        XCTAssertTrue(element("mark-viewed-deleted.txt").exists)
        XCTAssertFalse(element("mark-viewed-stale.txt").exists)
        XCTAssertEqual(app.buttons.matching(identifier: "workspace-change-unviewed-shared.txt").count, 1)

        let taskID = try taskID(named: "Git changes")
        let inventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((inventory?["unviewed"] as? [[String: Any]])?.count, 7)
        XCTAssertEqual((inventory?["viewed"] as? [[String: Any]])?.count, 0)
        let shared = try runCLI([
            "task", "changes", "diff", taskID,
            "--repository", fixture.changes.path,
            "--path", "shared.txt",
            "--group", "unviewed"
        ])["result"] as? [String: Any]
        XCTAssertEqual(shared?["original"] as? String, "Shared baseline.\n")
        XCTAssertEqual(shared?["modified"] as? String, "Shared working version.\n")
        assertCLIError(
            try runCLI([
                "task", "changes", "diff", taskID,
                "--repository", fixture.changes.path,
                "--path", "stale.txt",
                "--group", "unviewed",
            ], expectedStatus: 3),
            code: "not_found"
        )

        element("workspace-change-unviewed-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        assertText("workspace-diff-title", equals: "shared.txt")
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Since branch base")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        let firstEditorStatus = monacoEditorStatus()
        XCTAssertTrue(
            firstEditorStatus.hasPrefix("Editor 1 ") && firstEditorStatus.hasSuffix(", showing shared.txt"),
            "The first diff must render in Monaco's first load. The editor reported ‘\(firstEditorStatus)’."
        )
        attachScreenshot(named: "The first diff opens in the side-by-side editor")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("workspace-diff-overlay").waitForNonExistence(timeout: 2))

        element("mark-viewed-shared.txt").click()
        // Marking saves a snapshot and stages the file asynchronously.
        var marked: [String: Any]?
        XCTAssertTrue(waitUntil({
            marked = try? self.runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
            return ((marked?["viewed"] as? [[String: Any]]) ?? []).contains { $0["path"] as? String == "shared.txt" }
        }, timeout: 10), "Marking a file viewed should persist its Viewed entry.")
        XCTAssertFalse(((marked?["unviewed"] as? [[String: Any]]) ?? []).contains { $0["path"] as? String == "shared.txt" })
        element("viewed-changes-section").click()
        XCTAssertTrue(element("workspace-change-viewed-shared.txt").waitToExist(timeout: 10))
        XCTAssertFalse(element("mark-viewed-shared.txt").exists, "Viewed entries must not offer the mark-viewed action.")
        try "Edited after viewing.\n".write(to: fixture.changes.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(
            element("workspace-change-unviewed-shared.txt").waitToExist(timeout: 10),
            "A later edit should be listed as a change still to review."
        )
        XCTAssertTrue(
            element("workspace-change-viewed-shared.txt").exists,
            "The already-reviewed work should stay listed under Viewed."
        )
        element("workspace-change-viewed-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Since branch base")
        let reviewedMonacoValue = renderedDiffValue()
        XCTAssertTrue(reviewedMonacoValue.contains("Original:\nShared baseline.\n"))
        XCTAssertTrue(
            reviewedMonacoValue.contains("Modified:\nShared working version.\n"),
            "The viewed diff must stay at the reviewed snapshot, not follow later edits."
        )
        app.typeKey(.escape, modifierFlags: [])
        element("workspace-change-unviewed-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Since last viewed")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        let viewedMonacoValue = renderedDiffValue()
        XCTAssertTrue(viewedMonacoValue.contains("Original:\nShared working version.\n"))
        XCTAssertTrue(viewedMonacoValue.contains("Modified:\nEdited after viewing.\n"))
        XCTAssertEqual(element("workspace-change-unviewed-shared.txt").value as? String, "Uncommitted, green")
        XCTAssertEqual(element("workspace-change-viewed-shared.txt").value as? String, "Uncommitted, green")
        app.typeKey(.escape, modifierFlags: [])
        attachScreenshot(named: "A re-edited file is listed under both Viewed and Changes")

        element("mark-viewed-untracked.txt").click()
        XCTAssertTrue(element("workspace-change-viewed-untracked.txt").waitToExist(timeout: 10))
        let stagedStatus = try runGitOutput(fixture.changes, "status", "--porcelain", "--", "untracked.txt")
        XCTAssertEqual(
            stagedStatus.trimmingCharacters(in: .whitespacesAndNewlines),
            "A  untracked.txt",
            "Marking a new file viewed should stage it so later edits are detected."
        )
        try "Untracked file, edited after viewing.\n".write(to: fixture.changes.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-untracked.txt").waitToExist(timeout: 10))
        XCTAssertTrue(element("workspace-change-viewed-untracked.txt").exists)
        element("workspace-change-unviewed-untracked.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        let recreatedUntrackedValue = renderedDiffValue()
        XCTAssertTrue(recreatedUntrackedValue.contains("Original:\nUntracked file.\n"))
        XCTAssertTrue(recreatedUntrackedValue.contains("Modified:\nUntracked file, edited after viewing.\n"))
        app.typeKey(.escape, modifierFlags: [])

        element("mark-viewed-deleted.txt").click()
        // The viewed snapshot is saved asynchronously; recreating the file first would be reviewed too.
        XCTAssertTrue(waitUntil({
            let inventory = try? self.runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
            return ((inventory?["viewed"] as? [[String: Any]]) ?? []).contains { $0["path"] as? String == "deleted.txt" }
        }, timeout: 10), "Marking the deletion viewed should persist before the file is recreated.")
        try "Recreated after viewing.\n".write(to: fixture.changes.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-deleted.txt").waitToExist(timeout: 10))
        XCTAssertTrue(element("workspace-change-viewed-deleted.txt").exists)
        assertText("workspace-change-viewed-deleted.txt", equals: "deleted.txt, deleted, reviewed")
        assertText("workspace-change-unviewed-deleted.txt", equals: "deleted.txt, added, pending")
        element("workspace-change-unviewed-deleted.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        let recreatedMonacoValue = renderedDiffValue()
        XCTAssertTrue(recreatedMonacoValue.contains("Original:\n\nModified:\nRecreated after viewing.\n"))
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(
            try runCLI(["task", "changes", "mark-viewed", taskID, "--repository", fixture.changes.path, "--path", "stale.txt"], expectedStatus: 3),
            code: "not_found"
        )

        // A file that never existed in the branch base, created then renamed away by two
        // separate file operations (not `git mv`, which Git would recognize as one rename),
        // nets to zero change once both the deletion and the replacement are reviewed.
        try "Ephemeral content.\n".write(to: fixture.changes.appendingPathComponent("ephemeral.txt"), atomically: true, encoding: .utf8)
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(element("mark-viewed-ephemeral.txt").waitToExist(timeout: 10))
        element("mark-viewed-ephemeral.txt").click()
        XCTAssertTrue(element("workspace-change-viewed-ephemeral.txt").waitToExist(timeout: 10))
        try FileManager.default.removeItem(at: fixture.changes.appendingPathComponent("ephemeral.txt"))
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(
            element("workspace-change-unviewed-ephemeral.txt").waitToExist(timeout: 10),
            "Deleting a reviewed new file lists the deletion as a change still to review."
        )
        element("mark-viewed-ephemeral.txt").click()
        // The viewed snapshot is saved asynchronously; a refresh started before it lands still lists the old entry.
        XCTAssertTrue(waitUntil({
            let inventory = try? self.runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
            let listed = ((inventory?["viewed"] as? [[String: Any]]) ?? []) + ((inventory?["unviewed"] as? [[String: Any]]) ?? [])
            return inventory != nil && !listed.contains { $0["path"] as? String == "ephemeral.txt" }
        }, timeout: 10), "Reviewing the deletion of a never-committed file should leave it out of the persisted inventory.")
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(
            element("workspace-change-viewed-ephemeral.txt").waitForNonExistence(timeout: 10),
            "A reviewed file with no base content and no current file is zero net change, not a ghost entry."
        )
        XCTAssertFalse(element("workspace-change-unviewed-ephemeral.txt").exists)
        try "Reborn content.\n".write(to: fixture.changes.appendingPathComponent("ephemeral.txt"), atomically: true, encoding: .utf8)
        element("refresh-workspace-changes-button").click()
        XCTAssertTrue(
            element("workspace-change-unviewed-ephemeral.txt").waitToExist(timeout: 10),
            "Recreating the file afterward surfaces it as a fresh change to review."
        )

        element("workspace-change-unviewed-untracked.txt").click()
        assertText("workspace-diff-title", equals: "untracked.txt")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        XCTAssertEqual(
            monacoEditorStatus(),
            "Editor 1 reused, showing untracked.txt",
            "Reopening a diff must reuse Monaco's first load instead of loading the editor again."
        )
        element("workspace-change-unviewed-syntax.json").click()
        XCTAssertNotEqual(
            element("workspace-diff-editor-status").value as? String,
            "Editor 1 reused, showing untracked.txt",
            "The warm editor must stop presenting the previous file as soon as another one is opened."
        )
        assertText("workspace-diff-title", equals: "syntax.json")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        XCTAssertEqual(
            monacoEditorStatus(),
            "Editor 1 reused, showing syntax.json",
            "Switching files keeps rendering in the same warm editor."
        )
        let reusedEditorValue = renderedDiffValue()
        XCTAssertTrue(
            reusedEditorValue.contains("Modified:\n{\"value\":\"working version\"}"),
            "The reused editor must show the newly opened file, not the previous diff."
        )
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        attachScreenshot(named: "A later diff opens in the already-loaded side-by-side editor")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("empty-conversation").exists, "Closing the diff should reveal the conversation again.")

        let changeDiagnostics = try diagnosticEvents()
        XCTAssertTrue(changeDiagnostics.contains {
            $0["event"] as? String == "workspace.files.inventory.succeeded" && Int($0["unviewedCount"] as? String ?? "0") ?? 0 > 0
        })
        XCTAssertTrue(changeDiagnostics.contains { $0["event"] as? String == "workspace.file.read.succeeded" })
        XCTAssertFalse(
            String(describing: changeDiagnostics).contains("Shared working version."),
            "Diagnostics must not log changed file contents."
        )
    }
    // case-contract: test_task_workspace_changes_mark_all_viewed_and_unview | The Changes section header offers Mark all as viewed while it lists files: one action saves a viewed snapshot of every current Changes entry and stages each in Git, so Changes empties and every file is listed under Viewed, and the operation reports how many files it marked, zero when nothing is pending. Each Viewed entry offers Mark as unviewed, which drops that file's snapshot without touching the Git index, so its whole change from the branch base is listed under Changes again; unviewing a file that isn't a current Viewed entry, including one already unviewed and an unknown path, is rejected. These results persist across fresh CLI/XPC connections. The Changes section collapses inside the task sidebar, hiding its Viewed and Changes lists while its header and pending count stay visible and the sidebar stays open for other sections; separately, the whole sidebar hides to a narrow rail that still shows how many files are pending. Each collapsed or expanded state is its own global preference, so opening another task keeps it. Once loaded, refreshing a task with no changes keeps its No changes state on screen instead of flashing the loading placeholder.
    func test_task_workspace_changes_mark_all_viewed_and_unview() throws {
        let cleanRepository = runDirectory.appendingPathComponent("clean-changes", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanRepository, withIntermediateDirectories: true)
        try "Baseline.\n".write(to: cleanRepository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(cleanRepository, "init", "--initial-branch=main")
        try runGit(cleanRepository, "config", "user.name", "Playhouse UI Test")
        try runGit(cleanRepository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(cleanRepository, "add", "tracked.txt")
        try runGit(cleanRepository, "commit", "-m", "Baseline")
        // This case builds its own changed repository: the shared fixture is prepared only for
        // the staged/unstaged case and is left modified by it within a batch.
        let changes = runDirectory.appendingPathComponent("review-parent/changes", isDirectory: true)
        try FileManager.default.createDirectory(at: changes, withIntermediateDirectories: true)
        let baseline = [
            "staged.txt": "Staged baseline.\n",
            "shared.txt": "Shared baseline.\n",
            "working.txt": "Working baseline.\n",
            "deleted.txt": "Deleted baseline.\n",
            "staged-deleted.txt": "Staged deletion baseline.\n",
            "syntax.json": "{\"value\":\"baseline\"}\n",
        ]
        for (path, contents) in baseline {
            try contents.write(to: changes.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try runGit(changes, "init", "--initial-branch=main")
        try runGit(changes, "config", "user.name", "Playhouse UI Test")
        try runGit(changes, "config", "user.email", "playhouse-ui-test@example.invalid")
        try runGit(changes, "add", ".")
        try runGit(changes, "commit", "-m", "Baseline")
        try "Staged index version.\n".write(to: changes.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try "Shared index version.\n".write(to: changes.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "{\"value\":\"working version\"}\n".write(to: changes.appendingPathComponent("syntax.json"), atomically: true, encoding: .utf8)
        try runGit(changes, "add", "staged.txt", "shared.txt")
        try "Shared working version.\n".write(to: changes.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "Working tree version.\n".write(to: changes.appendingPathComponent("working.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: changes.appendingPathComponent("deleted.txt"))
        try "Untracked file.\n".write(to: changes.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try runGit(changes, "rm", "--quiet", "staged-deleted.txt")
        _ = try runCLI(["task", "create", "--title", "Mark all viewed", "--prompt", "Fixture task description.", "--root", changes.path])
        _ = try runCLI(["task", "create", "--title", "Clean changes", "--prompt", "Fixture task description.", "--root", cleanRepository.path])
        let taskID = try taskID(named: "Mark all viewed")
        let pendingPaths: Set<String> = ["deleted.txt", "shared.txt", "staged-deleted.txt", "staged.txt", "syntax.json", "untracked.txt", "working.txt"]

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Mark all viewed")
        XCTAssertTrue(element("workspace-change-unviewed-shared.txt").waitToExist(timeout: 10))
        XCTAssertTrue(element("mark-all-viewed-button").exists, "The Changes header offers Mark all as viewed while it lists files.")
        XCTAssertFalse(element("mark-unviewed-shared.txt").exists, "Changes entries offer mark-viewed, not unview.")
        attachScreenshot(named: "The Changes header offers Mark all as viewed")

        element("mark-all-viewed-button").click()
        var inventory: [String: Any]?
        XCTAssertTrue(waitUntil({
            inventory = try? self.runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
            return (inventory?["unviewed"] as? [[String: Any]])?.isEmpty == true
        }, timeout: 15), "Mark all as viewed should leave nothing pending.")
        XCTAssertEqual(Set(((inventory?["viewed"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }), pendingPaths)
        XCTAssertEqual(
            try runGitOutput(changes, "status", "--porcelain", "--", "untracked.txt").trimmingCharacters(in: .whitespacesAndNewlines),
            "A  untracked.txt",
            "Mark all as viewed should stage each file."
        )
        XCTAssertEqual(
            try runGitOutput(changes, "status", "--porcelain", "--", "staged-deleted.txt").trimmingCharacters(in: .whitespacesAndNewlines),
            "D  staged-deleted.txt",
            "An already staged deletion is accepted and stays staged."
        )
        XCTAssertTrue(element("workspace-change-unviewed-shared.txt").waitForNonExistence(timeout: 10))
        XCTAssertFalse(element("mark-all-viewed-button").exists, "With nothing pending, the header no longer offers Mark all as viewed.")
        element("viewed-changes-section").click()
        XCTAssertTrue(element("workspace-change-viewed-shared.txt").waitToExist(timeout: 10))
        for path in pendingPaths {
            XCTAssertTrue(element("workspace-change-viewed-\(path)").exists, "\(path) should be listed under Viewed.")
            XCTAssertTrue(element("mark-unviewed-\(path)").exists, "Each Viewed entry offers Mark as unviewed.")
        }
        XCTAssertFalse(element("mark-viewed-shared.txt").exists)
        attachScreenshot(named: "Every file is listed under Viewed with an unview action")

        element("mark-unviewed-shared.txt").click()
        XCTAssertTrue(element("workspace-change-unviewed-shared.txt").waitToExist(timeout: 10), "Unviewing lists the file under Changes again.")
        XCTAssertTrue(element("workspace-change-viewed-shared.txt").waitForNonExistence(timeout: 10))
        XCTAssertTrue(element("mark-viewed-shared.txt").exists)
        XCTAssertTrue(element("mark-all-viewed-button").exists)
        let afterUnview = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        let pendingAfterUnview = (afterUnview?["unviewed"] as? [[String: Any]]) ?? []
        XCTAssertEqual(pendingAfterUnview.compactMap { $0["path"] as? String }, ["shared.txt"])
        XCTAssertEqual(pendingAfterUnview.first?["hasViewedSnapshot"] as? Bool, false)
        XCTAssertEqual((afterUnview?["viewed"] as? [[String: Any]])?.count, pendingPaths.count - 1)
        XCTAssertEqual(
            try runGitOutput(changes, "status", "--porcelain", "--", "shared.txt").trimmingCharacters(in: .whitespacesAndNewlines),
            "M  shared.txt",
            "Unviewing leaves the Git index as it was."
        )
        element("workspace-change-unviewed-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitToExist(timeout: 10))
        assertText("workspace-diff-source", equals: "review-parent/changes · Since branch base")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("workspace-diff-overlay").waitForNonExistence(timeout: 2))
        attachScreenshot(named: "An unviewed file is listed under Changes again")
        assertCLIError(
            try runCLI(["task", "changes", "mark-unviewed", taskID, "--repository", changes.path, "--path", "shared.txt"], expectedStatus: 3),
            code: "not_found"
        )
        assertCLIError(
            try runCLI(["task", "changes", "mark-unviewed", taskID, "--repository", changes.path, "--path", "missing.txt"], expectedStatus: 3),
            code: "not_found"
        )

        // The Changes section collapses inside the sidebar, which stays open for other sections.
        assertText("toggle-workspace-changes-section-button", equals: "Expanded")
        element("toggle-workspace-changes-section-button").click()
        XCTAssertTrue(element("workspace-change-unviewed-shared.txt").waitForNonExistence(timeout: 5), "Collapsing the Changes section hides its lists.")
        XCTAssertFalse(element("unviewed-changes-section").exists)
        XCTAssertFalse(element("viewed-changes-section").exists)
        XCTAssertTrue(element("task-sidebar").exists, "Collapsing the section keeps the sidebar open.")
        XCTAssertFalse(element("task-sidebar-collapsed").exists)
        assertText("workspace-changes-title", equals: "Changes")
        assertText("toggle-workspace-changes-section-button", equals: "Collapsed")
        assertText("collapsed-workspace-changes-section-count", equals: "Changes to review: 1")
        XCTAssertGreaterThan(element("task-sidebar").frame.width, 200)
        attachScreenshot(named: "The collapsed Changes section keeps its header and pending count")

        openTask(named: "Clean changes")
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10))
        assertText("toggle-workspace-changes-section-button", equals: "Collapsed")
        XCTAssertFalse(element("workspace-changes-empty").exists, "The collapsed section state is global, so another task opens with it collapsed.")
        XCTAssertFalse(element("collapsed-workspace-changes-section-count").exists, "A task with nothing pending shows no count.")
        // The chevron's whole frame toggles, not only the drawn glyph at its center.
        element("toggle-workspace-changes-section-button").coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        XCTAssertTrue(element("workspace-changes-empty").waitToExist(timeout: 10), "Clicking the chevron's leading edge expands the section.")
        assertText("toggle-workspace-changes-section-button", equals: "Expanded")
        element("toggle-workspace-changes-section-button").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).click()
        XCTAssertTrue(element("workspace-changes-empty").waitForNonExistence(timeout: 5), "Clicking the chevron's trailing edge collapses the section.")
        assertText("toggle-workspace-changes-section-button", equals: "Collapsed")
        element("workspace-changes-title").click()
        XCTAssertTrue(element("workspace-changes-empty").waitToExist(timeout: 10), "Clicking the section title expands it.")
        assertText("toggle-workspace-changes-section-button", equals: "Expanded")

        // Every refresh used to swap No changes for the loading placeholder while Git ran.
        var sawLoadingPlaceholder = false
        for _ in 0..<3 {
            element("refresh-workspace-changes-button").click()
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                if element("workspace-changes-loading").exists || !element("workspace-changes-empty").exists {
                    sawLoadingPlaceholder = true
                }
            }
        }
        XCTAssertFalse(sawLoadingPlaceholder, "Refreshing a loaded task must keep No changes on screen instead of flashing the loading placeholder.")
        attachScreenshot(named: "No changes stays on screen across refreshes")

        // Separately, the whole sidebar hides to a narrow rail.
        element("hide-task-sidebar-button").click()
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 5), "The sidebar hides to a narrow rail.")
        XCTAssertFalse(element("workspace-changes-title").exists)
        XCTAssertFalse(element("collapsed-task-sidebar-count").exists, "A task with nothing pending shows no count.")
        XCTAssertLessThan(element("task-sidebar-collapsed").frame.width, 60)

        openTask(named: "Mark all viewed")
        XCTAssertTrue(element("task-sidebar-collapsed").waitToExist(timeout: 10), "The hidden sidebar state is global, so another task opens with it hidden.")
        assertText("collapsed-task-sidebar-count", equals: "Changes to review: 1")
        attachScreenshot(named: "The hidden sidebar keeps the pending count")
        element("show-task-sidebar-button").click()
        XCTAssertTrue(element("workspace-changes-title").waitToExist(timeout: 10))
        XCTAssertFalse(element("task-sidebar-collapsed").exists)
        assertText("toggle-workspace-changes-section-button", equals: "Expanded")
        XCTAssertTrue(
            element("workspace-change-unviewed-shared.txt").waitToExist(timeout: 10),
            "Expanding the section in one task expands it everywhere."
        )
    }
}

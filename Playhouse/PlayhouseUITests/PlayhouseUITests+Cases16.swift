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
    // case-contract: test_conversation_steers_and_queues_active_turn | When a steer misses its active turn, CLI/XPC and UI accept it into the durable queue for its own turn; opening an empty task waits for the model-aware prompt and omits the generic Start a conversation heading; with no active turn, missed composer and queued-row steers start their own turns without blocking other steering and leave the queue; queued fallback survives process exit or app relaunch and is drained exactly once; a missed regular or queued-row steer arriving during targeted queue dispatch is drained afterward exactly once; a follow-up being delivered stays claimed as dispatching and leaves the visible queue while its own turn runs; a missed queued-row steer from the CLI returns to the waiting queue and shows its row again in the app before the targeted turn ends; a failed targeted turn remains needs-action, stays out of the conversation history, and does not drain later messages; malformed steer images fail validation; CLI/XPC steering routes image data to a UI-owned active turn and appears in the conversation. Command-Return steers the active turn with attached text and images, then clears the accepted draft and image preview; if the active turn changes before delivery, it clears the draft and queues the complete message for its own turn; a steer the provider refuses for any other reason reports the provider's error, is not queued, and returns its text and image to the composer with no message left in the transcript. Plain Return queues a follow-up; while the composer has a draft during the active turn, Send replaces Stop and queues the follow-up with its attached image like Return, clears the draft and preview so Stop returns, and marks the row with its image count; the queued image persists across reopening without returning to the composer, and malformed queued images fail validation. Its row Steer uses the active turn ID, delivers both text and image to the provider, appears in the transcript with its image, and removes the item only after acceptance. The obsolete footer Queue and Steer buttons are absent and the active response control is labeled Stop response. Follow-ups persist across reopening, expose per-row Steer, delete, and more actions, and a distinct after-turn follow-up dispatches once after a matching completion and is removed only after successful delivery; removing an unknown queue ID fails without changing the queue.
    func test_conversation_steers_and_queues_active_turn() throws {
        let sharedFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-steer-queue-serial-success-wait")
        let fixtureOwner = try String(contentsOf: WorkspaceFixture.root.appendingPathComponent(WorkspaceFixture.ownerMarker), encoding: .utf8)
        XCTAssertEqual(fixtureOwner, WorkspaceFixture.ownerContents, "Only the prepared, owned fixture root may contain the executable app-server fixture.")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sharedFixture.path), "The focused active-turn fixture should be prepared as an executable by the UI runner.")
        for suffix in ["resolve-ready", "resolve-continue", "serial-first-turn", "serial-second-turn-started", "history", "reject-next-steer", "hold-next-queued-turn", "queued-turn-ready", "queued-turn-release", "fail-next-turn-start", "steers-received", "thread-start-pause", "thread-start-ready", "thread-start-release"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sharedFixture.path + ".\(suffix)"))
        }
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        codexFixtureExecutable = sharedFixture.path
        launchWindowTitle = "Playhouse · steer-queue-test"
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title == %@", launchWindowTitle!)).firstMatch.waitToExist(timeout: 5), "The configured launch title should identify the worktree in the window chrome.")
        try createTaskFixture(title: "Active turn message controls", roots: [fixture.primary.path])
        openTask(named: "Active turn message controls")

        let taskID = try taskID(named: "Active turn message controls")
        let firstPrompt = "Start the active turn before steering and queueing."
        let steeringText = "Keep the current approach and simplify the final change."
        let missedRowSteerText = "Queue this missed row steer for its own turn."
        let rowSteeringText = "Send this queued follow-up into the active turn."
        let queuedText = "After the current work, verify the saved follow-up."
        XCTAssertTrue(modelPrompt().waitToExist(timeout: 15), "Conversation history should finish loading before the composer is used.")
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists, "The empty state should not include the removed generic heading.")
        let composer = app.textViews.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(composer.waitToExist(timeout: 10), "The native message editor should be exposed as a text view.")
        let composerReady = waitUntil({ composer.isHittable }, timeout: 15)
        if !composerReady {
            attachScreenshot(named: "Composer unavailable before active-turn test")
        }
        XCTAssertTrue(composerReady, "The composer should be hittable before typing. enabled=\(composer.isEnabled), value=\(composer.value as? String ?? "<none>"), hittable=\(composer.isHittable), frame=\(composer.frame); \(app.debugDescription)")
        composer.click()
        composer.typeText(firstPrompt)
        XCTAssertEqual(composer.value as? String, firstPrompt, "The first prompt must be present before starting the fixture turn.")
        let sendButton = element("send-message-button")
        XCTAssertTrue(sendButton.isEnabled, "The exact first prompt should enable Send before starting the fixture turn. composer=\(composer.value as? String ?? "<none>"), composerEnabled=\(composer.isEnabled), sendEnabled=\(sendButton.isEnabled); \(app.debugDescription)")
        element("send-message-button").click()
        let ready = URL(fileURLWithPath: sharedFixture.path + ".resolve-ready")
        let release = URL(fileURLWithPath: sharedFixture.path + ".resolve-continue")
        let fixtureHeld = waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15)
        let activeFixtureHistoryText = (try? String(contentsOf: URL(fileURLWithPath: sharedFixture.path + ".history"), encoding: .utf8)) ?? "<missing>"
        let activeFixtureFiles = (try? FileManager.default.contentsOfDirectory(atPath: WorkspaceFixture.root.path))?
            .filter { $0.hasPrefix(URL(fileURLWithPath: sharedFixture.path).lastPathComponent) }
            .sorted() ?? []
        let fixtureDiagnostics = ((try? diagnosticEvents()) ?? []).filter {
            ["conversation.send.started", "conversation.send.failed", "codex.app_server.started"].contains($0["event"] as? String ?? "")
        }.map { event in
            event.filter { ["event", "executable", "phase", "reason", "clientPID", "codexPID", "activeThreadID", "activeTurnID"].contains($0.key) }
        }
        let errorElement = element("codex-chat-error")
        let visibleError = errorElement.exists ? errorElement.label : "<no visible error>"
        XCTAssertTrue(
            fixtureHeld,
            "The fixture should hold the current turn active. History: \(activeFixtureHistoryText); fixture files: \(activeFixtureFiles); send diagnostics: \(fixtureDiagnostics); visible error: \(visibleError)"
        )
        XCTAssertFalse(element("steer-current-turn-button").exists, "The old footer Steer button should be absent.")
        XCTAssertFalse(element("queue-message-after-turn-button").exists, "The old footer Queue button should be absent.")
        XCTAssertEqual(element("pause-response-button").label, "Stop response", "The active-turn control should match the reference stop affordance.")
        XCTAssertTrue(app.staticTexts["Ask for follow-up changes"].exists, "The active composer should identify follow-up changes.")
        let preservedDraft = "Keep this unsent draft while steering."
        composer.typeText(preservedDraft)
        let missedSteer = try runCLI(["conversation", "steer", taskID, "--message", "Queue this missed steer."])["result"] as? [String: Any]
        XCTAssertEqual(missedSteer?["accepted"] as? Bool, true)
        XCTAssertEqual(missedSteer?["queued"] as? Bool, true)
        XCTAssertEqual(composer.value as? String, preservedDraft, "A CLI steer should leave a non-empty composer draft unchanged.")
        let missedQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let missedQueueItem = try XCTUnwrap(missedQueue?.first(where: { $0["text"] as? String == "Queue this missed steer." }))
        XCTAssertEqual(missedQueueItem["state"] as? String, "queued")
        try runCLI(["conversation", "queue-remove", taskID, try XCTUnwrap(missedQueueItem["id"] as? String)])
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey(.delete, modifierFlags: [])
        let invalidImage = dataDirectory.appendingPathComponent("invalid-steer.png")
        try Data("not an image".utf8).write(to: invalidImage)
        let invalidSteer = try runCLI(
            ["conversation", "steer", taskID, "--message", steeringText, "--image", invalidImage.path],
            expectedStatus: 2,
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": sharedFixture.path]
        )
        assertCLIError(invalidSteer, code: "invalid_argument")
        let invalidQueue = try runCLI(
            ["conversation", "queue", taskID, "--message", "Reject this queued image.", "--image", invalidImage.path],
            expectedStatus: 2
        )
        assertCLIError(invalidQueue, code: "invalid_argument")
        let cliImage = dataDirectory.appendingPathComponent("cli-steer.png")
        let cliBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(cliBitmap.representation(using: .png, properties: [:])).write(to: cliImage)
        let remoteSteer = try runCLI(["conversation", "steer", taskID, "--message", steeringText, "--image", cliImage.path])["result"] as? [String: Any]
        XCTAssertEqual(remoteSteer?["accepted"] as? Bool, true, "CLI/XPC steering should route to the UI-owned active turn.")
        XCTAssertTrue(transcriptMessage(steeringText).waitToExist(timeout: 10))
        func userMessageID(_ text: String) -> String {
            let bubble = app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "user-message-", text)).firstMatch
            return bubble.exists ? String(bubble.identifier.dropFirst("user-message-".count)) : ""
        }
        let cliSteerID = userMessageID(steeringText)
        XCTAssertFalse(cliSteerID.isEmpty, "The CLI/XPC steer should render as a user message.")
        let transcriptImages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-image-"))
        XCTAssertTrue(transcriptImages.firstMatch.waitToExist(timeout: 5), "An image-bearing CLI/XPC steer should render in the visible transcript. \(app.debugDescription)")
        XCTAssertEqual(transcriptImages.count, 1)
        let uiSteeringText = "Make the final change concise and focused."
        let uiBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let uiPNG = try XCTUnwrap(uiBitmap.representation(using: .png, properties: [:]))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(uiPNG, forType: .png)
        composer.click()
        composer.typeText(uiSteeringText)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "An image attached to a steer should remain previewed until accepted.")
        let steersReceived = sharedFixture.path + ".steers-received"
        try? FileManager.default.removeItem(atPath: steersReceived)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(transcriptMessage(uiSteeringText).waitToExist(timeout: 2), "Command-Return should show the steer in the transcript at once.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: steersReceived) }, timeout: 10), "Command-Return should steer the active turn with the composer text and image.")
        // The earlier steer may have scrolled out of the lazy stack below the newer one: check
        // each steer's own image rather than counting what is on screen.
        // The bubble's ID is looked up again on each poll: it changes when the saved message
        // replaces the one the window showed first.
        var uiSteerID = ""
        XCTAssertTrue(waitUntil({
            uiSteerID = userMessageID(uiSteeringText)
            return !uiSteerID.isEmpty && self.element("chat-image-\(uiSteerID)-0").exists
        }, timeout: 10), "The Command-Return steer should render as a user message with its image.")
        XCTAssertFalse(element("chat-image-\(uiSteerID)-1").exists, "The Command-Return steer should show its one image once.")
        // The newest turn renders eagerly, so its exact counts still hold: one bubble for the steer
        // and one image outside the earlier steer, whether or not that steer is rendered now.
        XCTAssertEqual(app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "user-message-", uiSteeringText)).count, 1,
                       "The Command-Return steer should render once.")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "chat-image-", "chat-image-\(cliSteerID)-"
        )).count, 1, "Only the Command-Return steer's image should join the transcript.")
        XCTAssertTrue(scrollTranscriptUntilExists(element("chat-image-\(cliSteerID)-0")), "The earlier CLI/XPC steer should keep its image.")
        XCTAssertFalse(element("chat-image-\(cliSteerID)-1").exists, "The earlier CLI/XPC steer should keep exactly its one image.")
        XCTAssertFalse(element("pending-chat-images").exists, "An accepted steer should clear its image preview.")
        XCTAssertEqual(composer.value as? String, "", "An accepted Command-Return steer should clear the draft.")
        let rejectNextSteer = sharedFixture.path + ".reject-next-steer"
        let missedUISteerText = "Queue this missed UI steer with its image."
        let userBubbles: (String) -> Int = { text in
            self.app.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "user-message-", text)).count
        }
        // A refusal that is not a missed turn is an error: the steer returns to the composer.
        let queueBeforeRefusal = try XCTUnwrap(try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]).count
        try "The fixture refused this steer.\n".write(to: URL(fileURLWithPath: rejectNextSteer), atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(uiPNG, forType: .png)
        composer.click()
        composer.typeText(missedUISteerText)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The steer's image should be previewed before Command-Return.")
        composer.typeKey(.return, modifierFlags: .command)
        let refusedSteerError = element("codex-chat-error")
        XCTAssertTrue(refusedSteerError.waitToExist(timeout: 10), "A steer Codex refuses for another reason should report the error.")
        XCTAssertTrue(refusedSteerError.label.localizedCaseInsensitiveContains("refused this steer"), "The error should be the provider's: \(refusedSteerError.label)")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == missedUISteerText }, timeout: 5), "A refused steer's text should return to the composer.")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "A refused steer's image should return to the composer.")
        XCTAssertTrue(waitUntil({ userBubbles(missedUISteerText) == 0 }, timeout: 5), "A refused steer should leave the transcript.")
        XCTAssertEqual((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.count, queueBeforeRefusal, "A refused steer must not be queued.")
        attachScreenshot(named: "Refused steer returns to the composer with its error")
        // The same steer again, now missing the turn: it is queued for a turn of its own.
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: rejectNextSteer), atomically: true, encoding: .utf8)
        composer.click()
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: rejectNextSteer) }, timeout: 10), "Codex should miss the steer.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).contains { $0["text"] as? String == missedUISteerText }
        }, timeout: 10), "A missed UI steer should be accepted into the follow-up queue.")
        XCTAssertEqual(composer.value as? String, "", "A missed UI steer should leave the composer clear.")
        XCTAssertTrue(waitUntil({ userBubbles(missedUISteerText) == 0 }, timeout: 5), "A missed steer waits in the queue, not in the transcript.")
        XCTAssertFalse(element("codex-chat-error").exists, "A missed UI steer should not show an error.")
        let missedUISteerQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let missedUISteerItem = try XCTUnwrap(missedUISteerQueue?.first(where: { $0["text"] as? String == missedUISteerText }))
        XCTAssertEqual(missedUISteerItem["state"] as? String, "queued")
        let queuedImages = try XCTUnwrap(missedUISteerItem["imageDataURLs"] as? [String])
        XCTAssertEqual(queuedImages.count, 1, "The queued fallback should preserve its attached image.")
        XCTAssertTrue(queuedImages[0].hasPrefix("data:image/png;base64,"))
        XCTAssertFalse(element("pending-chat-images").exists, "Queue acceptance should clear the attached image preview.")
        composer.click()
        composer.typeText(missedRowSteerText)
        composer.typeKey(.return, modifierFlags: [])
        let queued = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        XCTAssertEqual(queued?.count, 2, "Both the missed composer steer and the ordinary follow-up should be queued.")
        let missedRowItem = try XCTUnwrap(queued?.first(where: { $0["text"] as? String == missedRowSteerText }))
        let queuedID = try XCTUnwrap(missedRowItem["id"] as? String)
        let queuedRowText = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(queuedRowText.waitToExist(timeout: 10), "Queued text should be visible in its composer row. app=\(app.debugDescription)")
        XCTAssertEqual(queuedRowText.value as? String, missedRowSteerText, "The queue row should expose the actual follow-up text.")
        XCTAssertTrue(element("steer-queued-message-\(queuedID)").exists, "A queued follow-up should offer a per-row steer action.")
        XCTAssertTrue(element("queued-message-more-\(queuedID)").exists, "A queued follow-up should offer its more-actions menu.")
        element("back-to-board-button").click()
        openTask(named: "Active turn message controls")
        let reopenedQueuedRow = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(reopenedQueuedRow.waitToExist(timeout: 10), "The queued row should render after reopening the task during the active turn.")
        XCTAssertEqual(reopenedQueuedRow.value as? String, missedRowSteerText)
        XCTAssertTrue(element("steer-queued-message-\(queuedID)").exists, "Reopening should restore the queued row Steer action.")
        try "expected active turn id stale-turn but found fixture-turn\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        element("steer-queued-message-\(queuedID)").click()
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: rejectNextSteer) }, timeout: 10), "Codex should miss the row's steer.")
        XCTAssertTrue(element("queued-message-text-\(queuedID)").waitToExist(timeout: 10), "A missed queued steer should return to the visible queue.")
        XCTAssertTrue(waitUntil({ userBubbles(missedRowSteerText) == 0 }, timeout: 5), "A missed row steer waits in the queue, not in the transcript.")
        XCTAssertFalse(element("codex-chat-error").exists, "A missed queued steer should not surface an error.")
        var fallbackQueue: [[String: Any]]?
        XCTAssertTrue(waitUntil({
            fallbackQueue = try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
            return fallbackQueue?.first(where: { $0["id"] as? String == queuedID })?["state"] as? String == "queued"
        }, timeout: 10), "A missed row steer should remain queued for its own turn.")
        let missedRowFallback = try XCTUnwrap(fallbackQueue?.first(where: { $0["id"] as? String == queuedID }))
        element("back-to-board-button").click()
        openTask(named: "Active turn message controls")
        let reopenedMissedRow = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(reopenedMissedRow.waitToExist(timeout: 10), "The missed row steer should persist in queued state after reopening.")
        XCTAssertEqual(missedRowFallback["text"] as? String, missedRowSteerText)
        let retainedAfterInvalidRemoval = try runCLI(["conversation", "queue", taskID, "--message", "Keep this queued after an unknown removal."])["result"] as? [String: Any]
        let retainedQueueID = try XCTUnwrap(retainedAfterInvalidRemoval?["id"] as? String)
        let invalidRemoval = try runCLI(
            ["conversation", "queue-remove", taskID, "00000000-0000-0000-0000-000000000000"],
            expectedStatus: 1
        )
        assertCLIError(invalidRemoval, code: "invalid_transition")
        let retainedQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let retainedQueueIDs = retainedQueue?.compactMap { $0["id"] as? String } ?? []
        XCTAssertTrue(retainedQueueIDs.contains(retainedQueueID), "Removing an unknown ID must leave existing queued follow-ups unchanged.")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(uiPNG, forType: .png)
        XCTAssertEqual(composer.value as? String ?? "", "", "The composer should be empty before typing the second follow-up.")
        XCTAssertEqual(element("pause-response-button").label, "Stop response", "The fixture turn should still be active, showing Stop, before typing a second follow-up.")
        XCTAssertFalse(element("send-message-button").exists, "An empty composer during an active turn shows Stop, not Send.")
        composer.click()
        composer.typeText(rowSteeringText)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The queued follow-up's image should be previewed before Return.")
        XCTAssertEqual(composer.value as? String, rowSteeringText, "The native composer should contain the second follow-up before Return.")
        // With a draft, Send takes Stop's place while the turn is still running.
        let activeTurnSend = element("send-message-button")
        XCTAssertTrue(activeTurnSend.waitToExist(timeout: 5), "Send should replace Stop while the composer has a draft. app=\(app.debugDescription)")
        XCTAssertFalse(element("pause-response-button").exists, "Stop should give way to Send while the composer has a draft.")
        XCTAssertTrue(activeTurnSend.isEnabled, "Send should be enabled during the active turn when the composer has a draft.")
        attachScreenshot(named: "Send replaces Stop while a follow-up is typed")
        attachElementScreenshot(activeTurnSend, named: "The Send button during an active turn")
        activeTurnSend.click()
        var acceptedQueue: [[String: Any]]?
        XCTAssertTrue(waitUntil({
            acceptedQueue = try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
            return acceptedQueue?.contains(where: { $0["text"] as? String == rowSteeringText }) == true
        }, timeout: 5), "Send should queue the typed follow-up while the active turn is held. composer=\(composer.value as? String ?? "<none>"), error=\(element("codex-chat-error").exists ? element("codex-chat-error").label : "<none>"), fixtureHeld=\(FileManager.default.fileExists(atPath: ready.path))")
        XCTAssertEqual(composer.value as? String ?? "", "", "Send should clear the queued draft.")
        let activeTurnControl = element("pause-response-button")
        XCTAssertTrue(activeTurnControl.waitToExist(timeout: 5), "Stop should return once the queued draft clears the composer.")
        XCTAssertEqual(activeTurnControl.label, "Stop response")
        XCTAssertTrue(activeTurnControl.isEnabled, "Stop should still pause the running turn after Send queues a follow-up.")
        let acceptedQueueItem = try XCTUnwrap(acceptedQueue?.first(where: { $0["text"] as? String == rowSteeringText }))
        let acceptedQueueID = try XCTUnwrap(acceptedQueueItem["id"] as? String)
        let acceptedQueueImages = try XCTUnwrap(acceptedQueueItem["imageDataURLs"] as? [String], "Send should queue the attached image with the follow-up.")
        XCTAssertEqual(acceptedQueueImages.count, 1)
        XCTAssertTrue(acceptedQueueImages[0].hasPrefix("data:image/png;base64,"))
        XCTAssertFalse(element("pending-chat-images").exists, "Queueing a follow-up should clear its image preview.")
        XCTAssertTrue(element("queued-message-images-\(acceptedQueueID)").waitToExist(timeout: 5), "A queued row should show that it carries an image.")
        XCTAssertEqual(element("queued-message-images-\(acceptedQueueID)").label, "1 attached image")
        attachScreenshot(named: "Queued follow-up with an attached image")
        element("back-to-board-button").click()
        openTask(named: "Active turn message controls")
        XCTAssertTrue(element("queued-message-images-\(acceptedQueueID)").waitToExist(timeout: 10), "The queued row's image should persist across reopening.")
        XCTAssertFalse(element("pending-chat-images").exists, "A queued image must not return to the composer after reopening.")
        element("steer-queued-message-\(acceptedQueueID)").click()
        XCTAssertTrue(waitUntil({
            !((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == acceptedQueueID }
        }, timeout: 10), "Steering a queued row should remove it after successful delivery.")
        // The window applies the delivery the queue reports, so its row goes once that lands.
        XCTAssertTrue(waitUntil({ !self.element("queued-message-text-\(acceptedQueueID)").exists }, timeout: 5), "Successful steering should remove the queued text from its row.")
        XCTAssertTrue(transcriptMessage(rowSteeringText).waitToExist(timeout: 10), "Per-row steering should appear in the active conversation.")
        // Earlier steers render only near the viewport, so check the steered row's own image
        // rather than counting what is rendered.
        let rowSteerID = userMessageID(rowSteeringText)
        XCTAssertFalse(rowSteerID.isEmpty, "The steered queued row should render as a user message.")
        XCTAssertTrue(element("chat-image-\(rowSteerID)-0").waitToExist(timeout: 10), "A steered queued row should show its image in the transcript. \(app.debugDescription)")
        XCTAssertFalse(element("chat-image-\(rowSteerID)-1").exists, "A steered queued row should show its one image once.")
        // The steered row starts the newest turn, which renders in full, and every earlier row lies
        // above it, so every image at or below its bubble must be its own one image: a duplicate
        // attached to any other message of the turn would show up here.
        let rowSteerBubble = element("user-message-\(rowSteerID)")
        let imagesFromRowSteerDown = transcriptImages.allElementsBoundByIndex.filter { $0.frame.minY >= rowSteerBubble.frame.minY - 1 }
        XCTAssertEqual(imagesFromRowSteerDown.map(\.identifier), ["chat-image-\(rowSteerID)-0"],
                       "Only the steered row's image should join the transcript from its message down.")
        attachScreenshot(named: "Steered queued follow-up shows its image")
        composer.click()
        composer.typeText("Remove this queued row.")
        composer.typeKey(.return, modifierFlags: [])
        let removable = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == "Remove this queued row." }))
        let removableID = try XCTUnwrap(removable["id"] as? String)
        element("remove-queued-message-\(removableID)").click()
        XCTAssertTrue(waitUntil({
            !((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == removableID }
        }, timeout: 10), "Removing a queued row should persist through CLI/XPC.")
        XCTAssertTrue(waitUntil({ !element("queued-message-text-\(removableID)").exists }, timeout: 5), "Removing a queued follow-up should remove the visible row.")
        composer.click()
        composer.typeText(queuedText)
        composer.typeKey(.return, modifierFlags: [])
        let afterTurnRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == queuedText }))
        let afterTurnRowID = try XCTUnwrap(afterTurnRow["id"] as? String)
        let afterTurnRowText = element("queued-message-text-\(afterTurnRowID)")
        XCTAssertTrue(afterTurnRowText.waitToExist(timeout: 10), "The after-turn follow-up should appear as a visible queue row before delivery.")

        try "Release the active turn.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The queued message should dispatch once after the matching completed notification.")
        XCTAssertTrue(waitUntil({ !afterTurnRowText.exists }, timeout: 10), "The accepted after-turn follow-up should disappear from the visible queue.")
        XCTAssertTrue(transcriptMessage(queuedText).waitToExist(timeout: 10), "The accepted after-turn follow-up should appear in the conversation transcript.")
        // No turn is running now, so the composer would send; queue the row directly.
        let targetedText = "Retry this row as its own turn."
        let targetedRow = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", targetedText])["result"] as? [String: Any])
        let targetedID = try XCTUnwrap(targetedRow["id"] as? String)
        try "hold targeted delivery\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(targetedID)").waitToExist(timeout: 5))
        element("steer-queued-message-\(targetedID)").click()
        let targetedReady = URL(fileURLWithPath: sharedFixture.path + ".queued-turn-ready")
        let targetedRelease = URL(fileURLWithPath: sharedFixture.path + ".queued-turn-release")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 10), "A row steer with no active turn should start a targeted own-turn delivery.")
        let deliveringRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["id"] as? String == targetedID }))
        XCTAssertEqual(deliveringRow["state"] as? String, "dispatching", "A follow-up stays durably claimed while its own turn runs.")
        XCTAssertTrue(waitUntil({ !element("queued-message-text-\(targetedID)").exists }, timeout: 5), "A follow-up being delivered should leave the visible queue while its turn runs.")
        XCTAssertFalse(element("steer-queued-message-\(targetedID)").exists, "A follow-up being delivered should not offer Steer.")
        let availableRow = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", "Another follow-up remains steerable."])["result"] as? [String: Any])
        let availableID = try XCTUnwrap(availableRow["id"] as? String)
        let availableSteer = element("steer-queued-message-\(availableID)")
        XCTAssertTrue(availableSteer.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ availableSteer.isEnabled }, timeout: 10), "A fallback turn must not leave other steering buttons disabled.")
        attachScreenshot(named: "Delivering follow-up leaves other steering available")
        let steeringAttachment = XCTAttachment(screenshot: availableSteer.screenshot())
        steeringAttachment.name = "Follow-up steering remains available"
        steeringAttachment.lifetime = .keepAlways
        add(steeringAttachment)
        availableSteer.click()
        XCTAssertTrue(transcriptMessage("Another follow-up remains steerable.").waitToExist(timeout: 10), "The available button must deliver its message during the held fallback turn.")
        let overlapText = "Queue this steer behind the targeted turn."
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        let overlapSteer = try runCLI(["conversation", "steer", taskID, "--message", overlapText], extraEnvironment: [
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": sharedFixture.path
        ])["result"] as? [String: Any]
        XCTAssertEqual(overlapSteer?["accepted"] as? Bool, true)
        XCTAssertEqual(overlapSteer?["queued"] as? Bool, true, "A missed steer during targeted dispatch should queue for the deferred full drain.")
        let overlapRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == overlapText }))
        XCTAssertEqual(overlapRow["state"] as? String, "queued")
        try "Release targeted delivery.\n".write(to: targetedRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The deferred full drain should deliver the overlapping missed steer after targeted dispatch.")
        let targetedRowText = "Retry another row as its own turn."
        let targetedRowOverlap = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", targetedRowText])["result"] as? [String: Any])
        let targetedRowID = try XCTUnwrap(targetedRowOverlap["id"] as? String)
        try "hold targeted row delivery\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(targetedRowID)").waitToExist(timeout: 5))
        element("steer-queued-message-\(targetedRowID)").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 10), "The targeted row turn should be held while a second row steer is submitted.")
        let missedRowOverlapText = "Queue this missed row steer behind targeted dispatch."
        composer.click()
        composer.typeText(missedRowOverlapText)
        composer.typeKey(.return, modifierFlags: [])
        let missedRowOverlap = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == missedRowOverlapText }))
        let missedRowOverlapID = try XCTUnwrap(missedRowOverlap["id"] as? String)
        try "expected active turn id stale-turn but found fixture-turn\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(missedRowOverlapID)").waitToExist(timeout: 5))
        // Steer from the CLI, so this window learns of the requeue only through the bridge.
        let missedRowSteer = try XCTUnwrap(try runCLI(["conversation", "queue-steer", taskID, missedRowOverlapID])["result"] as? [String: Any])
        XCTAssertEqual(missedRowSteer["queued"] as? Bool, true, "A missed queued-row steer should stay queued while targeted dispatch is active.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).first(where: { $0["id"] as? String == missedRowOverlapID })?["state"] as? String == "queued"
        }, timeout: 10), "The missed queued-row steer should remain queued until the targeted turn ends.")
        XCTAssertTrue(element("queued-message-text-\(missedRowOverlapID)").waitToExist(timeout: 5), "A missed queued-row steer from the CLI should show its row again in the app before the targeted turn ends.")
        XCTAssertTrue(element("steer-queued-message-\(missedRowOverlapID)").exists, "The returned row should offer Steer again.")
        attachScreenshot(named: "Missed row steer returns to the queue")
        relaunchApp()
        openTask(named: "Active turn message controls")
        let relaunchedMissedRow = element("queued-message-text-\(missedRowOverlapID)")
        XCTAssertTrue(relaunchedMissedRow.waitToExist(timeout: 10), "The missed queued-row steer should remain visible after app relaunch.")
        XCTAssertEqual(relaunchedMissedRow.value as? String, missedRowOverlapText)
        let persistedMissedRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["id"] as? String == missedRowOverlapID }))
        XCTAssertEqual(persistedMissedRow["state"] as? String, "queued", "App relaunch must not turn a durable queued steer into Needs action.")
        try "Release targeted row delivery.\n".write(to: targetedRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The pending drain should deliver the missed queued-row steer after targeted delivery.")
        XCTAssertFalse(element("codex-chat-error").exists, "A missed queued-row steer during targeted delivery should not show an error.")
        let regularFallbackText = "Deliver a missed regular steer without blocking."
        let raceRow = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", "Start the turn that will finish during steering."])["result"] as? [String: Any])
        let raceID = try XCTUnwrap(raceRow["id"] as? String)
        try "hold race turn\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(raceID)").waitToExist(timeout: 10))
        element("steer-queued-message-\(raceID)").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 10))
        try "hold regular fallback\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        try "complete before rejecting\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".complete-before-steer-rejection"), atomically: true, encoding: .utf8)
        composer.click()
        composer.typeText(regularFallbackText)
        // The race turn's marker is still there; without it, its return means the fallback turn is held.
        try FileManager.default.removeItem(at: targetedReady)
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 15), "The missed composer steer should run as a held turn of its own.")
        XCTAssertEqual(composer.value as? String, "", "A missed composer steer should leave the composer clear while its fallback is held.")
        let regularAvailable = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", "Steer while regular fallback runs."])["result"] as? [String: Any])
        let regularAvailableID = try XCTUnwrap(regularAvailable["id"] as? String)
        let regularButton = element("steer-queued-message-\(regularAvailableID)")
        XCTAssertTrue(regularButton.waitToExist(timeout: 10))
        XCTAssertTrue(regularButton.isEnabled)
        regularButton.click()
        XCTAssertTrue(transcriptMessage("Steer while regular fallback runs.").waitToExist(timeout: 10))
        try "Release regular fallback.\n".write(to: targetedRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty }, timeout: 20))
        XCTAssertTrue(transcriptMessage(regularFallbackText).waitToExist(timeout: 10))
        let immediateSteerText = "Deliver this missed row immediately as its own turn."
        let immediateRow = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", immediateSteerText])["result"] as? [String: Any])
        let immediateRowID = try XCTUnwrap(immediateRow["id"] as? String)
        let immediateSteerButton = element("steer-queued-message-\(immediateRowID)")
        XCTAssertTrue(immediateSteerButton.waitToExist(timeout: 10), "A queued follow-up should be visible while no turn is active.")
        immediateSteerButton.click()
        XCTAssertTrue(transcriptMessage(immediateSteerText).waitToExist(timeout: 10), "A missed steer with no active turn should be delivered visibly in its own turn.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 10), "The synchronous own-turn drain should remove the queued row before completion is reported.")
        let immediateHistory = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let immediateMessages = (immediateHistory?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(immediateMessages.filter { $0["text"] as? String == immediateSteerText }.count, 1)
        let failedTargetText = "This targeted queued turn should need action."
        let laterText = "Keep this later message queued after a failure."
        // No turn is running now, so the composer would send; queue the rows directly.
        _ = try runCLI(["conversation", "queue", taskID, "--message", failedTargetText])
        _ = try runCLI(["conversation", "queue", taskID, "--message", laterText])
        let failureQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let failedTarget = try XCTUnwrap(failureQueue?.first(where: { $0["text"] as? String == failedTargetText }))
        let laterItem = try XCTUnwrap(failureQueue?.first(where: { $0["text"] as? String == laterText }))
        let failedTargetID = try XCTUnwrap(failedTarget["id"] as? String)
        let laterID = try XCTUnwrap(laterItem["id"] as? String)
        try "fail targeted turn start\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".fail-next-turn-start"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(failedTargetID)").waitToExist(timeout: 5))
        element("steer-queued-message-\(failedTargetID)").click()
        XCTAssertTrue(waitUntil({
            let items = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []
            return items.first(where: { $0["id"] as? String == failedTargetID })?["state"] as? String == "needsAction" &&
                items.first(where: { $0["id"] as? String == laterID })?["state"] as? String == "queued"
        }, timeout: 10), "A failed targeted turn should need action while later follow-ups stay queued.")
        let needsActionIndicator = element("queued-message-needs-action-\(failedTargetID)")
        XCTAssertTrue(needsActionIndicator.waitToExist(timeout: 5), "The failed targeted row should visibly require user action.")
        XCTAssertEqual(accessibleLabelOrValue(of: needsActionIndicator), "Follow-up needs your action")
        XCTAssertTrue(element("retry-queued-message-\(failedTargetID)").exists, "The failed targeted row should expose its retry action.")
        XCTAssertTrue(waitUntil({ userBubbles(failedTargetText) == 0 }, timeout: 5), "A follow-up whose turn never started should not stay in the transcript.")
        XCTAssertTrue(element("queued-message-text-\(laterID)").exists, "The later queued row should remain visible after the targeted failure.")
        let history = try runCLI(["conversation", "history", taskID], extraEnvironment: [
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": sharedFixture.path
        ])["result"] as? [String: Any]
        let userMessages = (history?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(userMessages.compactMap { $0["text"] as? String }.filter { $0 == queuedText }.count, 1)
        XCTAssertFalse(userMessages.contains { $0["text"] as? String == failedTargetText }, "A queued follow-up whose turn never started must not be recorded as sent.")
        XCTAssertEqual(userMessages.compactMap { $0["text"] as? String }.filter { $0 == missedUISteerText }.count, 1, "The missed composer steer should be in the conversation once, from its own turn.")
        let fixtureHistory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sharedFixture.path + ".history"))) as? [String: Any]
        )
        let deliveredTurns = try XCTUnwrap(fixtureHistory["messages"] as? [[String: Any]])
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == missedRowSteerText }.count, 1, "A missed row steer should dispatch exactly once as its own turn.")
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == targetedText }.count, 1, "A targeted row dispatch should be delivered exactly once.")
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == overlapText }.count, 1, "A missed steer queued during targeted dispatch should be delivered exactly once afterward.")
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == targetedRowText }.count, 1, "A second targeted row dispatch should be delivered exactly once.")
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == missedRowOverlapText }.count, 1, "A missed queued-row steer during targeted dispatch should be delivered exactly once afterward.")
        XCTAssertEqual(deliveredTurns.filter { $0["userMessage"] as? String == immediateSteerText }.count, 1, "A missed no-active-turn steer should be delivered exactly once before its request returns.")
        let imageFallbackTurn = try XCTUnwrap(deliveredTurns.first { $0["userMessage"] as? String == missedUISteerText })
        let deliveredImages = try XCTUnwrap(imageFallbackTurn["images"] as? [String])
        XCTAssertEqual(deliveredImages.count, 1, "The missed composer steer should retain its image through normal queued delivery.")
        XCTAssertTrue(deliveredImages[0].hasPrefix("data:image/png;base64,"))
        let steerRequests = try XCTUnwrap(fixtureHistory["steerRequests"] as? [[String: Any]])
        let rejectedSteerRequests = fixtureHistory["rejectedSteerRequests"] as? [[String: Any]] ?? []
        // The daemon owns the targeted turns too, so both CLI steers sent during
        // them (the overlap steer and the missed row steer) reach Codex and are
        // rejected before they queue.
        XCTAssertEqual(rejectedSteerRequests.count, 7, "Rejected steers: \(rejectedSteerRequests.map { ($0["input"] as? [[String: Any]])?.first?["text"] as? String ?? "?" })")
        XCTAssertEqual(steerRequests.count, 5)
        XCTAssertEqual((steerRequests[3]["input"] as? [[String: String]])?.first?["text"], "Another follow-up remains steerable.")
        XCTAssertEqual(steerRequests[3]["expectedTurnId"] as? String, deliveredTurns.first(where: { $0["userMessage"] as? String == targetedText })?["turnID"] as? String)
        let activeTurnID = (fixtureHistory["messages"] as? [[String: Any]])?.first?["turnID"] as? String
        XCTAssertEqual(steerRequests[0]["expectedTurnId"] as? String, activeTurnID)
        let remoteSteerInput = try XCTUnwrap(steerRequests[0]["input"] as? [[String: String]])
        XCTAssertEqual(remoteSteerInput[0], ["type": "text", "text": steeringText])
        XCTAssertEqual(remoteSteerInput[1]["type"], "image")
        XCTAssertTrue(remoteSteerInput[1]["url"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(steerRequests[1]["expectedTurnId"] as? String, activeTurnID, "Command-Return steering must include the current turn ID.")
        let uiSteerInput = try XCTUnwrap(steerRequests[1]["input"] as? [[String: String]])
        XCTAssertEqual(uiSteerInput[0], ["type": "text", "text": uiSteeringText])
        XCTAssertEqual(uiSteerInput[1]["type"], "image")
        XCTAssertTrue(uiSteerInput[1]["url"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(steerRequests[2]["expectedTurnId"] as? String, activeTurnID, "Queued-row Steer must target the current turn.")
        XCTAssertEqual(
            steerRequests[2]["input"] as? [[String: String]],
            [["type": "text", "text": rowSteeringText], ["type": "image", "url": acceptedQueueImages[0]]],
            "Steering a queued row should deliver its image to the active turn, not only its text."
        )
    }
    // case-contract: test_conversation_sends_image_attachments | Backlog draft images persist through fresh CLI/XPC reads and reopening the conversation, with the preview restored; saving more than 8 draft images fails with invalid_argument and preserves the existing attachment. The composer's attach button, left of the Plan button, opens a file panel limited to images, and the chosen image appears in the composer preview and persists as a draft image until removed; a non-image file picked anyway (through Go to Folder) is refused with an image-only error and adds no draft image. The conversation composer also accepts pasted images, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, stores those image URLs with the turn in Playhouse's transcript store, and keeps earlier images visible after a later text turn and history refresh. The provider-neutral conversation present-image API is included in agent instructions, validates and persists agent-produced PNG and JPEG files as assistant messages, and reopening the conversation renders each image visibly. Diagnostics record image MIME and encoded size without storing image payloads. Clicking a composer attachment, a user transcript attachment, or an agent-published assistant image opens the original image in a large viewer, which can be closed to return to the conversation; a published assistant image preserves the original file bytes.

    func test_conversation_sends_image_attachments() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Image conversation", roots: [fixture.primary.path])
        openTask(named: "Image conversation")
        let image = dataDirectory.appendingPathComponent("chat-image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        // The attach button opens a file panel that takes images; the chosen image joins the draft.
        // A larger, coloured image keeps the attached preview visible in the screenshot.
        let attachImage = dataDirectory.appendingPathComponent("attach-image.png")
        let attachBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<64 { attachBitmap.setColor(NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 1), atX: x, y: y) } }
        try attachBitmap.representation(using: .png, properties: [:])!.write(to: attachImage)
        let notAnImage = dataDirectory.appendingPathComponent("notes.txt")
        try "Not an image".write(to: notAnImage, atomically: true, encoding: .utf8)
        let attachButton = element("composer-attach-button")
        XCTAssertTrue(attachButton.waitToExist(timeout: 10))
        XCTAssertEqual(attachButton.label, "Attach files")
        XCTAssertLessThanOrEqual(attachButton.frame.maxX, element("conversation-plan-button").frame.minX, "The attach button sits left of the Plan button.")
        attachButton.click()
        let attachPanel = openFolderPanel
        XCTAssertTrue(attachPanel.waitToExist(timeout: 10), "The attach button opens a file panel.")
        func goTo(_ path: String) {
            attachPanel.typeKey("g", modifierFlags: [.command, .shift])
            let goToSheet = app.sheets.firstMatch
            XCTAssertTrue(goToSheet.waitToExist(timeout: 5), "Go to Folder did not open from the attach panel.")
            let pathField = goToSheet.textFields.firstMatch
            XCTAssertTrue(pathField.waitToExist(timeout: 5))
            pathField.click()
            pathField.typeKey("a", modifierFlags: .command)
            pathField.typeText(path)
            pathField.typeKey(.return, modifierFlags: [])
        }
        let attachConfirm = attachPanel.buttons["Attach"]
        // The panel lists images only, but Go to Folder can still pick another file; the composer refuses it.
        goTo(notAnImage.path)
        if waitUntil({ attachConfirm.exists && attachConfirm.isEnabled }, timeout: 5) { attachConfirm.click() }
        XCTAssertTrue(waitUntil({ !attachPanel.exists }, timeout: 5), "Attach closes the panel.")
        let attachError = element("codex-chat-error")
        XCTAssertTrue(attachError.waitToExist(timeout: 5), "Attaching a non-image file shows an error.")
        XCTAssertTrue(attachError.label.contains("Only images can be attached"), "The error names the image-only limit: \(attachError.label)")
        XCTAssertFalse(element("pending-chat-images").exists, "A refused non-image file adds no preview.")
        let refusedTaskID = try XCTUnwrap(try taskRecord(named: "Image conversation")?["id"] as? String)
        XCTAssertEqual((try taskRecord(id: refusedTaskID)?["draftImageDataURLs"] as? [String]) ?? [], [], "A refused non-image file adds no draft image.")
        attachButton.click()
        XCTAssertTrue(attachPanel.waitToExist(timeout: 10), "The attach button reopens the file panel.")
        goTo(attachImage.path)
        XCTAssertTrue(waitUntil({ attachConfirm.exists && attachConfirm.isEnabled }, timeout: 10), "Choosing the image enables Attach.")
        attachConfirm.click()
        XCTAssertTrue(waitUntil({ !attachPanel.exists }, timeout: 5), "Attach closes the panel.")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The chosen image appears in the composer preview.")
        let attachedTaskID = try XCTUnwrap(try taskRecord(named: "Image conversation")?["id"] as? String)
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: attachedTaskID))??["draftImageDataURLs"] as? [String])?.first?.hasPrefix("data:image/png;base64,") == true }, timeout: 5),
                      "The attached image persists as a draft image.")
        attachScreenshot(named: "Composer: an image attached with the attach button")
        attachRegionScreenshot([attachButton, element("pending-chat-images")], named: "Composer close-up: the attach button and the attached image")
        app.buttons["Remove image"].firstMatch.click()
        XCTAssertTrue(waitUntil({ !self.element("pending-chat-images").exists }, timeout: 5), "Removing the attached image clears the preview.")
        let pasteComposer = element("message-composer")
        XCTAssertTrue(pasteComposer.waitToExist(timeout: 10))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try Data(contentsOf: image), forType: .png)
        pasteComposer.click()
        pasteComposer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The pasted image should appear in the composer preview.")
        let pendingImage = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pending-chat-image-")).firstMatch
        XCTAssertTrue(pendingImage.waitToExist(timeout: 5))
        let pendingThumbnailFrame = pendingImage.frame
        pendingImage.click()
        let pendingFullSizeImage = element("chat-image-full-size")
        XCTAssertTrue(pendingFullSizeImage.waitToExist(timeout: 5), "Clicking a composer attachment should open its image in the large viewer.")
        XCTAssertGreaterThan(pendingFullSizeImage.frame.width, pendingThumbnailFrame.width, "The composer attachment viewer should be larger than its thumbnail.")
        element("close-chat-image-viewer").click()
        XCTAssertFalse(element("chat-image-full-size").exists, "Closing the composer image viewer should return to the conversation.")
        let imageTask = try XCTUnwrap(taskRecord(named: "Image conversation"))
        let imageTaskID = try XCTUnwrap(imageTask["id"] as? String)
        let freshImageTask = try XCTUnwrap(try runCLI(["task", "get", imageTaskID])["result"] as? [String: Any])
        let draftImages = try XCTUnwrap(freshImageTask["draftImageDataURLs"] as? [String])
        XCTAssertEqual(draftImages.count, 1, "The backlog task should persist its unsent image attachment.")
        XCTAssertTrue(draftImages[0].hasPrefix("data:image/png;base64,"))
        let excessImageArguments = (0..<9).flatMap { _ in ["--image", image.path] }
        let rejectedDraft = try runCLI(
            ["task", "prompt", imageTaskID, "--text", ""] + excessImageArguments,
            expectedStatus: 2
        )
        XCTAssertEqual((rejectedDraft["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        let preservedImageTask = try XCTUnwrap(try taskRecord(id: imageTaskID))
        XCTAssertEqual(preservedImageTask["draftImageDataURLs"] as? [String], draftImages)
        XCTAssertEqual(freshImageTask["draftImageDataURLs"] as? [String], draftImages)
        element("back-to-board-button").click()
        openTask(named: "Image conversation")
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "Reopening a backlog task should restore its image preview.")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("What is shown in this screenshot?")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        let pickedTurnHistoryURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        var pickedTurnJSON: [String: Any]?
        XCTAssertTrue(waitUntil({
            guard let pickedTurnData = try? Data(contentsOf: pickedTurnHistoryURL),
                  let history = try? JSONSerialization.jsonObject(with: pickedTurnData) as? [String: Any],
                  history["userMessage"] as? String == "What is shown in this screenshot?" else {
                return false
            }
            pickedTurnJSON = history
            return true
        }, timeout: 5), "The fixture should persist the sent text before the question response is inspected.")
        let pickedTurn = try XCTUnwrap(pickedTurnJSON)
        XCTAssertTrue((pickedTurn["threadStartDeveloperInstructions"] as? String)?.contains("conversation present-image") == true, "The agent should receive instructions for publishing images into chat.")
        XCTAssertEqual(pickedTurn["userMessage"] as? String, "What is shown in this screenshot?")
        XCTAssertEqual((pickedTurn["images"] as? [String])?.count, 1, "The fixture should receive the pasted image alongside the text prompt.")
        let pickedImage = try XCTUnwrap((pickedTurn["images"] as? [String])?.first)
        XCTAssertTrue(pickedImage.hasPrefix("data:image/png;base64,"), "The fixture should receive the image as a data URL.")
        XCTAssertEqual(pickedTurn["imageInputs"] as? [[String: String]], [["type": "image", "url": pickedImage]], "The Codex request should use the tagged image URL payload.")
        var imageDiagnostics: [[String: Any]] = []
        XCTAssertTrue(waitUntil({
            imageDiagnostics = (try? self.diagnosticEvents()) ?? []
            return !imageDiagnostics.isEmpty
        }, timeout: 5), "The visible attachment send should leave diagnostics.")
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: imageDiagnostics), encoding: .utf8)?.contains(pickedImage) ?? true)
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: imageTaskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 10), "The first image turn should settle before the follow-up turn starts.")
        // Playhouse names stored messages after its own turns, so read the IDs from the store.
        let firstHistory = try runCLI(["conversation", "history", imageTaskID])["result"] as? [String: Any]
        let firstMessages = firstHistory?["messages"] as? [[String: Any]] ?? []
        let imagePromptID = try XCTUnwrap(firstMessages.first {
            $0["role"] as? String == "user" && !($0["imageDataURLs"] as? [String] ?? []).isEmpty
        }?["id"] as? String)
        let firstAnswerID = try XCTUnwrap(firstMessages.first {
            $0["role"] as? String == "assistant" && $0["text"] as? String == "Answers received: Blue / fixture-secret."
        }?["id"] as? String)
        let firstAnswer = element("assistant-message-\(firstAnswerID)")
        XCTAssertTrue(firstAnswer.waitToExist(timeout: 10))
        XCTAssertEqual(firstAnswer.label, "Answers received: Blue / fixture-secret.")
        XCTAssertTrue(element("user-message-\(imagePromptID)").waitToExist(timeout: 10), "Reloaded history should retain the pasted attachment.")
        XCTAssertTrue(element("chat-image-\(imagePromptID)-0").waitToExist(timeout: 10), "Conversation history should render the pasted image.")

        let followupPrompt = "Continue using the earlier image as context."
        // A draft shows Send even while a turn runs, so wait for idle before typing it.
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 10), "The first image turn should settle before the follow-up.")
        composer.click()
        composer.typeText(followupPrompt)
        let composerEnabled = waitUntil({ self.element("send-message-button").isEnabled }, timeout: 10)
        let recentCodexEvents = ((try? diagnosticEvents()) ?? []).suffix(20).compactMap { $0["event"] as? String }
        XCTAssertTrue(composerEnabled, "The composer should be enabled after the first image turn settles. Recent events: \(recentCodexEvents)")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10), "The follow-up turn should refresh the existing conversation history.")
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        let followupMessage = transcriptMessage(followupPrompt)
        XCTAssertTrue(followupMessage.waitToExist(timeout: 10), "The follow-up prompt should appear in the conversation.")
        // Visible replies to hidden outcome reminders are assistant rows too, so match the answer itself.
        let followupAnswer = app.groups.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@ AND label == %@",
            "assistant-message-", "assistant-message-\(firstAnswerID)",
            "Answers received: Blue / fixture-secret."
        )).firstMatch
        XCTAssertTrue(followupAnswer.waitToExist(timeout: 10), "The follow-up answer should render as its own assistant message.")
        XCTAssertTrue(revealWholeTranscript(), "The earlier image turn should load as the reader scrolls up.")
        XCTAssertTrue(scrollTranscriptUntilExists(element("chat-image-\(imagePromptID)-0")), "Refreshing history after another turn should keep the earlier image visible.")
        let refreshedHistory = try runCLI(["conversation", "history", try taskID(named: "Image conversation")])["result"] as? [String: Any]
        let refreshedUserMessages = (refreshedHistory?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(refreshedUserMessages.first?["imageDataURLs"] as? [String], [pickedImage], "A fresh XPC history read should retain the earlier image after a later turn.")

        let agentCaption = "Agent generated screenshot"
        // A wide image makes the viewer's width depend on the sheet's own width, so the
        // size assertion below pins the large viewer instead of the fitted square height.
        let wideAgentImage = dataDirectory.appendingPathComponent("agent-wide-image.png")
        let wideBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try wideBitmap.representation(using: .png, properties: [:])!.write(to: wideAgentImage)
        let agentImage = try runCLI(["conversation", "present-image", try taskID(named: "Image conversation"), "--image", wideAgentImage.path, "--caption", agentCaption])["result"] as? [String: Any]
        XCTAssertEqual(agentImage?["role"] as? String, "assistant")
        XCTAssertEqual(agentImage?["text"] as? String, agentCaption)
        XCTAssertEqual((agentImage?["imageDataURLs"] as? [String])?.first?.hasPrefix("data:image/png;base64,"), true)
        let agentImageID = try XCTUnwrap(agentImage?["id"] as? String)
        let agentJPEG = dataDirectory.appendingPathComponent("agent-chat-image.jpg")
        try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: agentJPEG)
        let agentJPEGMessage = try runCLI(["conversation", "present-image", try taskID(named: "Image conversation"), "--image", agentJPEG.path, "--caption", "Agent JPEG screenshot"])["result"] as? [String: Any]
        XCTAssertEqual((agentJPEGMessage?["imageDataURLs"] as? [String])?.first?.hasPrefix("data:image/jpeg;base64,"), true)
        let agentJPEGID = try XCTUnwrap(agentJPEGMessage?["id"] as? String)

        element("back-to-board-button").click()
        openTask(named: "Image conversation")
        XCTAssertTrue(waitUntil({ self.transcriptContains(agentCaption) }, timeout: 10), "The agent image caption should appear as an assistant message after reopening.")
        XCTAssertTrue(element("chat-image-\(agentImageID)-0").waitToExist(timeout: 10), "The specific agent-published image should render in its assistant message after reopening.")
        XCTAssertTrue(element("chat-image-\(agentJPEGID)-0").waitToExist(timeout: 10), "The specific agent-published JPEG should render in its assistant message after reopening.")
        let agentThumbnail = app.buttons["chat-image-\(agentImageID)-0"]
        XCTAssertTrue(agentThumbnail.waitToExist(timeout: 5), "An agent-published assistant image should be clickable.")
        XCTAssertTrue(scrollFullyIntoView(agentThumbnail, in: element("conversation-scroll-view")), "The agent-published image should scroll into view before it is clicked.")
        let agentThumbnailFrame = agentThumbnail.frame
        agentThumbnail.click()
        let agentFullSizeImage = element("chat-image-full-size")
        XCTAssertTrue(agentFullSizeImage.waitToExist(timeout: 5), "Clicking an agent-published assistant image should open it in the large viewer.")
        XCTAssertGreaterThan(agentFullSizeImage.frame.width, agentThumbnailFrame.width, "The viewer should display the assistant image larger than its transcript thumbnail.")
        // The 520pt assistant thumbnail would still be beaten by a 600pt-wide sheet, so pin
        // the floor above what the smaller sheet can produce.
        XCTAssertGreaterThan(agentFullSizeImage.frame.width, 800, "The full-size viewer must stay large enough to be a real preview, not a slightly bigger thumbnail.")
        element("close-chat-image-viewer").click()
        XCTAssertFalse(element("chat-image-full-size").exists, "Closing the assistant image viewer should return to the conversation.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))
        try createTaskFixture(title: "Pasted image conversation", roots: [fixture.primary.path])
        openTask(named: "Pasted image conversation")

        let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixelBytes = try XCTUnwrap(largeBitmap.bitmapData)
        var pixelState: UInt32 = 0x5EED1234
        for y in 0..<1500 {
            for x in 0..<3000 {
                let offset = y * largeBitmap.bytesPerRow + x * 4
                pixelState = pixelState &* 1_664_525 &+ 1_013_904_223
                pixelBytes[offset] = UInt8(truncatingIfNeeded: pixelState >> 24)
                pixelState = pixelState &* 1_664_525 &+ 1_013_904_223
                pixelBytes[offset + 1] = UInt8(truncatingIfNeeded: pixelState >> 24)
                pixelState = pixelState &* 1_664_525 &+ 1_013_904_223
                pixelBytes[offset + 2] = UInt8(truncatingIfNeeded: pixelState >> 24)
                pixelBytes[offset + 3] = 0xFF
            }
        }
        let rawClipboardPNG = try XCTUnwrap(largeBitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(rawClipboardPNG.count, 10_000_000, "The clipboard source PNG should exceed the encoded payload limit.")
        XCTAssertGreaterThan(try XCTUnwrap(largeBitmap.tiffRepresentation).count, 10_000_000, "The clipboard TIFF representation should exceed the raw limit that previously caused rejection.")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(rawClipboardPNG, forType: .png)
        let pastedComposer = element("message-composer")
        pastedComposer.click()
        app.menuBars.menuBarItems["Edit"].click()
        let pasteMenuItem = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(pasteMenuItem.waitToExist(timeout: 5))
        XCTAssertTrue(pasteMenuItem.isEnabled, "The native text editor must enable Paste for an image-only clipboard.")
        pasteMenuItem.click()
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "Pasting an image should create a composer preview.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        let pastedAnswer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Answers received: Blue / fixture-secret.")
        ).firstMatch
        // Playhouse's outcome nudge can follow at once and push the answer out of the rendered rows.
        XCTAssertTrue(pastedAnswer.waitToExist(timeout: 10) || transcriptScan { pastedAnswer.exists }, "The pasted image's answer should be in the transcript.")
        let pastedHistory = try runCLI(["conversation", "history", try taskID(named: "Pasted image conversation")])["result"] as? [String: Any]
        let pastedPromptID = try XCTUnwrap((pastedHistory?["messages"] as? [[String: Any]] ?? []).first {
            $0["role"] as? String == "user" && !($0["imageDataURLs"] as? [String] ?? []).isEmpty
        }?["id"] as? String)
        XCTAssertTrue(element("user-message-\(pastedPromptID)").waitToExist(timeout: 10), "History reload should leave the pasted attachment in the conversation.")
        XCTAssertTrue(element("chat-image-\(pastedPromptID)-0").waitToExist(timeout: 10), "Conversation history should render the pasted image itself.")
        // The answer's turn ends with an outcome nudge whose reply reloads the transcript; the
        // thumbnail is clicked once that has settled the task, after scrolling it into view.
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: try self.taskID(named: "Pasted image conversation"))?["status"] as? String) == "Waiting Response"
        }, timeout: 15), "The pasted image turn should settle before its thumbnail is opened.")
        let transcriptImage = app.buttons["chat-image-\(pastedPromptID)-0"]
        XCTAssertTrue(transcriptImage.waitToExist(timeout: 5))
        XCTAssertTrue(scrollFullyIntoView(transcriptImage, in: element("conversation-scroll-view")),
                      "The pasted image should scroll into view before it is clicked.")
        let thumbnailFrame = transcriptImage.frame
        transcriptImage.click()
        let fullSizeImage = element("chat-image-full-size")
        XCTAssertTrue(fullSizeImage.waitToExist(timeout: 5), "Clicking a transcript attachment should open the original image in the large viewer.")
        XCTAssertEqual(fullSizeImage.label, "Full-size attached image")
        XCTAssertGreaterThan(fullSizeImage.frame.width, thumbnailFrame.width, "The viewer should display the image larger than its transcript thumbnail.")
        element("close-chat-image-viewer").click()
        XCTAssertFalse(element("chat-image-full-size").exists, "Closing the image viewer should return to the conversation.")
        let pastedTurnData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))
        let pastedTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: pastedTurnData) as? [String: Any])
        XCTAssertTrue(pastedTurn["userMessage"] is NSNull, "The fixture should receive no text for the pasted image-only turn.")
        XCTAssertEqual((pastedTurn["images"] as? [String])?.count, 1, "The fixture should receive the pasted image.")
        let pastedImage = try XCTUnwrap((pastedTurn["images"] as? [String])?.first)
        XCTAssertTrue(pastedImage.hasPrefix("data:image/jpeg;base64,"), "An oversized clipboard image should be compressed and reach Codex as JPEG.")
        let pastedPayload = try XCTUnwrap(Data(base64Encoded: String(pastedImage.split(separator: ",", maxSplits: 1)[1])))
        XCTAssertLessThanOrEqual(pastedPayload.count, 10_000_000, "The full-size clipboard image should fit the 10 MB payload limit.")
        XCTAssertEqual(pastedTurn["imageInputs"] as? [[String: String]], [["type": "image", "url": pastedImage]], "Image-only requests should use the tagged image URL payload.")
        imageDiagnostics = try diagnosticEvents()
        XCTAssertTrue(imageDiagnostics.contains {
            $0["event"] as? String == "bridge.request.succeeded"
                && $0["command"] as? String == "conversation.send"
                && $0["argument.images.0.mime"] as? String == "image/jpeg"
        }, "The compressed image-only request should retain JPEG MIME metadata in diagnostics.")
        let serializedImageDiagnostics = String(data: try JSONSerialization.data(withJSONObject: imageDiagnostics), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedImageDiagnostics.contains(pickedImage))
        XCTAssertFalse(serializedImageDiagnostics.contains(pastedImage))
        attachScreenshot(named: "Chat sends picker text-and-image and pasted image-only messages")
    }
    // case-contract: test_claude_agent_image_published_during_active_turn | While a Claude Code turn is active in the app process, the agent's CLI/XPC image publication joins that active Claude transcript turn; after the provider finishes, history places the image before the later assistant answer, and reopening the conversation renders the exact published image. Codex records the same active-turn attribution in the shared store, covered by test_codex_agent_image_published_during_active_turn.
    func test_claude_agent_image_published_during_active_turn() throws {
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        let executable = dataDirectory.appendingPathComponent("claude-fixture-active-image")
        try copyFixtureFile(at: source, to: executable)
        claudeFixtureExecutable = executable.path
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".history"))
        let ready = URL(fileURLWithPath: executable.path + ".image-turn-ready")
        let release = URL(fileURLWithPath: executable.path + ".image-turn-release")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: release)
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI([
            "task", "create", "--title", "Claude active image", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: "Claude active image")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Please publish-image-during-active-turn.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The Claude fixture should hold the app-owned turn before answering.")

        let image = dataDirectory.appendingPathComponent("active-agent-image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let published = try runCLI([
            "conversation", "present-image", taskID, "--image", image.path, "--caption", "During Claude turn",
        ])["result"] as? [String: Any]
        let imageID = try XCTUnwrap(published?["id"] as? String)
        try Data("Release Claude's turn.\n".utf8).write(to: release)
        XCTAssertTrue(app.staticTexts["Claude answer after the image."].waitToExist(timeout: 20))

        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let messages = try XCTUnwrap(history?["messages"] as? [[String: Any]])
        let imageIndex = try XCTUnwrap(messages.firstIndex { $0["id"] as? String == imageID })
        let answerIndex = try XCTUnwrap(messages.firstIndex { $0["text"] as? String == "Claude answer after the image." })
        XCTAssertLessThan(imageIndex, answerIndex, "The active-turn image should precede Claude's answer in the durable transcript.")
        element("back-to-board-button").click()
        openTask(named: "Claude active image")
        XCTAssertTrue(element("chat-image-\(imageID)-0").waitToExist(timeout: 10), "Reopening the Claude conversation should render the exact published image.")
    }
    // case-contract: test_claude_large_image_message_reaches_idle_agent | A Claude Code agent that has answered initialize and gone idle receives a user message carrying a screenshot larger than its input FIFO's buffer: the send completes with Claude's answer, the agent receives the whole image, the user message keeps that image when history is read over a fresh CLI/XPC connection and when the conversation is reopened, and a later text turn in the same conversation still completes. Claude Code's runtime, like the kqueue-reading fixture, is never woken by one oversized blocking write, so such a message must reach it without freezing the daemon. Codex agents talk over a socket and are not affected.
    func test_claude_large_image_message_reaches_idle_agent() throws {
        let source = WorkspaceFixture.root.appendingPathComponent("claude-fixture-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
        let executable = dataDirectory.appendingPathComponent("claude-fixture-large-image")
        try copyFixtureFile(at: source, to: executable)
        claudeFixtureExecutable = executable.path
        try Data("Playhouse test owns this Claude Code protocol fixture (v1).\n".utf8)
            .write(to: dataDirectory.appendingPathComponent(".playhouse-claude-fixture-owner"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".history"))
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI([
            "task", "create", "--title", "Claude screenshot", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "claude",
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: "Claude screenshot")

        // Random pixels barely compress, so the pasted screenshot is far larger than a FIFO's buffer.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) { pixels[offset] = UInt8.random(in: 0...255) }
        let screenshotPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(screenshotPNG, forType: .png)
        composer.click()
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitToExist(timeout: 5), "The pasted screenshot should appear in the composer.")
        composer.typeText("Describe this screenshot.")
        attachScreenshot(named: "Large screenshot ready to send to an idle Claude agent")
        element("send-message-button").click()
        // The send starts a fresh agent that answers initialize and goes idle before the message
        // arrives; a single blocking write of the message would leave every conversation frozen.
        XCTAssertTrue(app.staticTexts["OK."].waitToExist(timeout: 20), "Claude's answer to the screenshot message should appear.")

        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "user" && $0["text"] as? String == "Describe this screenshot." })
        let messageID = try XCTUnwrap(userMessage["id"] as? String)
        let imageURLs = try XCTUnwrap(userMessage["imageDataURLs"] as? [String])
        XCTAssertEqual(imageURLs.count, 1, "A fresh CLI/XPC read keeps the screenshot on the user message.")
        let encoded = try XCTUnwrap(imageURLs.first?.split(separator: ",", maxSplits: 1).last)
        XCTAssertGreaterThan(encoded.count, 64 * 1024, "The screenshot must not fit in a FIFO's buffer.")
        let turnsData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let turns = try XCTUnwrap((try JSONSerialization.jsonObject(with: turnsData) as? [String: Any])?["turns"] as? [[String: Any]])
        let imageTurn = try XCTUnwrap(turns.last { ($0["userText"] as? String)?.hasSuffix("Describe this screenshot.") == true })
        let received = try XCTUnwrap(imageTurn["images"] as? [[String: Any]])
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?["base64Length"] as? Int, encoded.count, "Claude Code should receive the whole image.")
        XCTAssertTrue(element("chat-image-\(messageID)-0").waitToExist(timeout: 10), "The sent screenshot should show in the transcript.")
        attachScreenshot(named: "Claude answered the large screenshot message")

        // Reopen while the screenshot turn is still the latest: a reopened conversation renders
        // from its newest user turn, and older turns page in on scroll.
        element("back-to-board-button").click()
        openTask(named: "Claude screenshot")
        XCTAssertTrue(element("chat-image-\(messageID)-0").waitToExist(timeout: 10), "Reopening the conversation should still show the screenshot.")
        attachScreenshot(named: "Reopened conversation keeps the screenshot")

        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Thanks, that is all.")
        element("send-message-button").click()
        let answers = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "OK.", "OK."))
        XCTAssertTrue(waitUntil({ answers.count >= 2 }, timeout: 20), "A later text turn in the same conversation should still complete.")
        attachScreenshot(named: "A later text turn completes after the screenshot")
    }
}

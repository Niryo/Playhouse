import XCTest

final class StationAIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dataDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StationAIUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )

        app = XCUIApplication()
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        app.launch()
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    func testCreateMoveAndPersistTaskAcrossRelaunch() throws {
        let boardTitle = app.staticTexts["board-title"]
        XCTAssertTrue(boardTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(boardTitle.isHittable, "Board title is not visible")
        XCTAssertEqual(app.staticTexts["task-count"].value as? String, "0")

        for columnID in ["column-backlog", "column-ready", "column-in-progress", "column-done"] {
            let column = column(withID: columnID)
            XCTAssertTrue(column.waitForExistence(timeout: 5), "Missing board column: \(columnID)")
            XCTAssertTrue(column.isHittable, "Board column is not visible: \(columnID)")
        }

        attachBoardScreenshot(named: "Empty kanban board")
        XCTAssertTrue(app.buttons["add-backlog-task-button"].isHittable)

        let tasks = [
            (title: "Add the first task", destination: "column-ready"),
            (title: "Review UI states", destination: "column-in-progress"),
            (title: "Build board search", destination: "column-done"),
        ]

        for (index, task) in tasks.enumerated() {
            createTask(
                named: task.title,
                checksEmptyValidation: index == 0,
                useBacklogAddButton: index == 0
            )
        }

        let backlog = column(withID: "column-backlog")
        for task in tasks {
            XCTAssertTrue(backlog.buttons[task.title].isHittable, "Task did not start in Backlog")
        }

        let taskCount = app.staticTexts["task-count"]
        XCTAssertTrue(taskCount.isHittable, "Task count is not visible")
        XCTAssertEqual(taskCount.value as? String, "3", "Task count did not update")

        for task in tasks {
            let taskLabel = backlog.buttons[task.title]
            let destination = column(withID: task.destination)
            taskLabel.press(forDuration: 0.8, thenDragTo: destination)
            // Keep this immediately after the drop so a lingering drag image is still visible.
            attachBoardScreenshot(named: "Immediately after drop - \(task.title)")

            let movedTask = destination.buttons[task.title]
            XCTAssertTrue(movedTask.waitForExistence(timeout: 5), "Task did not move to \(task.destination)")
            XCTAssertTrue(movedTask.isHittable, "Moved task is not visible in \(task.destination)")
            XCTAssertFalse(backlog.buttons[task.title].exists, "Moved task remained in Backlog")
        }

        attachBoardScreenshot(named: "Kanban board with tasks in every status")

        app.terminate()
        app.launch()

        let relaunchedTitle = app.staticTexts["board-title"]
        XCTAssertTrue(relaunchedTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunchedTitle.isHittable, "Board title is not visible after relaunch")
        attachBoardScreenshot(named: "Kanban board after relaunch")

        for task in tasks {
            let persistedTask = column(withID: task.destination).buttons[task.title]
            XCTAssertTrue(persistedTask.waitForExistence(timeout: 5), "Task status did not persist: \(task.title)")
            XCTAssertTrue(
                waitForHittable(persistedTask, timeout: 5),
                "Persisted task is not visible: \(task.title)"
            )
        }

        XCTAssertEqual(app.staticTexts["task-count"].value as? String, "3", "Task count did not persist across relaunch")

        let taskToOpen = tasks[0]
        let taskCard = app.buttons[taskToOpen.title]
        XCTAssertTrue(taskCard.waitForExistence(timeout: 5), "Task card is missing after relaunch")
        taskCard.click()

        let taskViewTitle = app.staticTexts["task-view-title"]
        XCTAssertTrue(taskViewTitle.waitForExistence(timeout: 5), "Task conversation did not open")
        XCTAssertEqual(taskViewTitle.value as? String, taskToOpen.title)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "task-sidebar").firstMatch.exists,
            "Task view is missing its sidebar"
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "empty-conversation").firstMatch.exists,
            "A new task conversation should start empty"
        )
        attachBoardScreenshot(named: "Empty task conversation")

        let composer = app.descendants(matching: .any)
            .matching(identifier: "message-composer")
            .firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Message composer is missing")
        composer.click()
        composer.typeText("Let's start with the first step.")

        let sendButton = app.buttons["send-message-button"]
        XCTAssertTrue(sendButton.isEnabled, "Send should enable after entering a message")
        sendButton.click()

        let sentMessage = app.staticTexts["sent-message-0"]
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 5), "Sent message was not added to the conversation")
        XCTAssertEqual(sentMessage.value as? String, "Let's start with the first step.")
        XCTAssertEqual(composer.value as? String, "", "Composer should clear after sending")
        attachBoardScreenshot(named: "Task conversation with sent message")

        let backButton = app.buttons["back-to-board-button"]
        XCTAssertTrue(backButton.isHittable, "Task view is missing its back button")
        backButton.click()
        XCTAssertTrue(relaunchedTitle.waitForExistence(timeout: 5), "Back button did not return to the Kanban board")
        XCTAssertTrue(app.buttons[taskToOpen.title].isHittable, "Task is missing after returning to the board")
    }

    private func createTask(
        named title: String,
        checksEmptyValidation: Bool,
        useBacklogAddButton: Bool = false
    ) {
        let createTaskButton = app.buttons[
            useBacklogAddButton ? "add-backlog-task-button" : "new-task-button"
        ]
        XCTAssertTrue(createTaskButton.isHittable)
        createTaskButton.click()

        let titleField = app.textFields["task-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))

        let confirmButton = app.buttons["create-task-button"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        if checksEmptyValidation {
            XCTAssertFalse(confirmButton.isEnabled, "A task must have a non-empty title")
        }

        titleField.click()
        titleField.typeText(title)
        XCTAssertTrue(confirmButton.isEnabled)
        confirmButton.click()

        let taskLabel = app.buttons[title]
        XCTAssertTrue(taskLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(taskLabel.isHittable, "Created task is not visible: \(title)")
    }

    private func column(withID identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachBoardScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

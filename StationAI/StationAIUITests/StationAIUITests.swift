import Foundation
import XCTest

final class StationAIUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: WorkspaceFixture!
    private var runDirectory: URL!
    private var dataDirectory: URL!
    private var preferencesSuiteName: String!
    private var appBundle: URL!
    private var cliURL: URL!
    private var serviceName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try WorkspaceFixture.load()
        runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StationAIUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(
            to: runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker),
            atomically: true,
            encoding: .utf8
        )
        dataDirectory = runDirectory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        preferencesSuiteName = "com.stationai.StationAI.E2E.\(UUID().uuidString)"

        appBundle = try Self.findAppBundle()
        cliURL = appBundle.appendingPathComponent("Contents/MacOS/stationai-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliURL.path), "The app-bundled CLI is missing.")
        let serviceInfo = appBundle.appendingPathComponent("Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist")
        let plistData = try Data(contentsOf: serviceInfo)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        serviceName = try XCTUnwrap(plist["CFBundleIdentifier"] as? String)
    }

    override func tearDownWithError() throws {
        if app?.state == .runningForeground || app?.state == .runningBackground {
            app.terminate()
        }
        UserDefaults(suiteName: preferencesSuiteName)?.removePersistentDomain(forName: preferencesSuiteName)

        let markerURL = runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == WorkspaceFixture.ownerContents else {
            XCTFail("Refusing to remove UI test data without its ownership marker: \(runDirectory.path)")
            return
        }
        try FileManager.default.removeItem(at: runDirectory)
    }

    // case-contract: test_service_reports_bridge_version | The real app window opens and the bridge reports StationAI API version 1.
    func test_service_reports_bridge_version() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15), "The StationAI window did not open.")
        let response = try runCLI(["status"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["service"] as? String, "StationAI")
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        attachScreenshot(named: "StationAI board opened with a healthy bridge")
    }

    // case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | Blank titles, missing roots, and unavailable roots cannot create a task.
    func test_task_creation_rejects_invalid_title_roots_and_missing_folder() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        let titleField = element("task-title-field")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        let done = element("create-task-button")
        XCTAssertFalse(done.isEnabled, "A task without a title and roots must not be creatable.")
        titleField.click()
        titleField.typeText("   ")
        XCTAssertFalse(done.isEnabled, "A whitespace title must not enable task creation.")

        assertCLIError(
            try runCLI(["task", "create", "--title", "   ", "--root", fixture.primary.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["task", "create", "--title", "No roots"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(
                ["task", "create", "--title", "Missing folder", "--root", fixture.missing.path],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        XCTAssertEqual(element("task-count").value as? String, "0")
        attachScreenshot(named: "Task creation validation blocks empty input")
    }

    // case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A task retains its title, Backlog state, and ordered roots after reopening.
    func test_task_creation_persists_ordered_roots_across_fresh_connections() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        element("task-title-field").click()
        element("task-title-field").typeText("Ordered roots")
        element("repository-suggestion-secondary").click()
        element("repository-suggestion-primary").click()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("create-task-button").click()
        openTask(named: "Ordered roots")
        let expectedRoots = [fixture.secondary.path, fixture.primary.path, fixture.custom.path]
        assertOrderedRoots(expectedRoots)

        let task = try XCTUnwrap(taskRecord(named: "Ordered roots"))
        XCTAssertEqual(task["status"] as? String, "Backlog")
        XCTAssertEqual(task["workspaceRoots"] as? [String], expectedRoots)
        let freshRead = try runCLI(["task", "get", try taskID(named: "Ordered roots")])
        let freshTask = try XCTUnwrap(freshRead["result"] as? [String: Any])
        XCTAssertEqual(freshTask["id"] as? String, task["id"] as? String)
        XCTAssertEqual(freshTask["title"] as? String, task["title"] as? String)
        XCTAssertEqual(freshTask["status"] as? String, task["status"] as? String)
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], expectedRoots)

        app.buttons["back-to-board-button"].click()
        relaunchApp()
        openTask(named: "Ordered roots")
        assertOrderedRoots(expectedRoots)
        attachScreenshot(named: "Ordered roots persist across UI and XPC reopen")
    }

    // case-contract: test_task_status_transitions_and_rejects_unknown_status | Tasks move through each supported status; invalid status leaves the task unchanged.
    func test_task_status_transitions_and_rejects_unknown_status() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Status transitions", roots: ["primary"])

        for status in ["Ready", "In Progress", "Done", "Backlog"] {
            dragTask("Status transitions", to: status)
            XCTAssertEqual(try taskRecord(named: "Status transitions")?["status"] as? String, status)
            assertTaskVisible("Status transitions", inColumn: status)
        }

        let taskID = try taskID(named: "Status transitions")
        assertCLIError(try runCLI(["task", "move", taskID, "Unknown"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try taskRecord(named: "Status transitions")?["status"] as? String, "Backlog")
        assertTaskVisible("Status transitions", inColumn: "Backlog")
        attachScreenshot(named: "Task status transitions across board columns")
    }

    // case-contract: test_task_rename_persists_and_rejects_blank_title | A rename persists; rejecting a blank rename preserves the last valid title.
    func test_task_rename_persists_and_rejects_blank_title() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Before rename", roots: ["primary"])
        let card = app.buttons["Before rename"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.rightClick()
        let renameAction = element("rename-task-menu-item")
        XCTAssertTrue(renameAction.waitForExistence(timeout: 5), "The task context menu has no rename action.")
        renameAction.click()

        let titleField = element("rename-task-title-field")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText("After rename")
        element("save-task-rename-button").click()
        XCTAssertTrue(app.buttons["After rename"].waitForExistence(timeout: 10))

        let taskID = try taskID(named: "After rename")
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        assertCLIError(
            try runCLI(["task", "rename", taskID, "--title", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        attachScreenshot(named: "Renamed task remains unchanged after rejected blank rename")
    }

    // case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, and rejects an empty list.
    func test_task_roots_set_get_order_deduplication_and_validation() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Edit roots", roots: ["primary"])
        openTask(named: "Edit roots")
        element("edit-workspace-roots-button").click()
        XCTAssertTrue(element("save-workspace-roots-button").waitForExistence(timeout: 5))

        element("repository-suggestion-secondary").click()
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "Remove secondary")).count,
            1
        )
        XCTAssertFalse(element("repository-suggestion-secondary").exists, "A selected repository must leave the suggestion list.")
        app.buttons["Remove primary"].click()
        app.buttons["Remove secondary"].click()
        let saveButton = element("save-workspace-roots-button")
        XCTAssertFalse(saveButton.isEnabled, "The editor must require at least one folder.")
        element("repository-suggestion-secondary").click()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("repository-suggestion-primary").click()
        saveButton.click()
        let expectedRoots = [fixture.secondary.path, fixture.custom.path, fixture.primary.path]
        assertOrderedRoots(expectedRoots)

        let taskID = try taskID(named: "Edit roots")
        let duplicateRoots = try runCLI([
            "task", "roots", "set", taskID,
            "--root", fixture.secondary.path,
            "--root", fixture.secondary.path,
            "--root", fixture.custom.path,
            "--root", fixture.primary.path
        ])
        XCTAssertEqual(
            (duplicateRoots["result"] as? [String: Any])?["workspaceRoots"] as? [String],
            expectedRoots
        )
        let result = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(result?["roots"] as? [String], expectedRoots)
        assertCLIError(try runCLI(["task", "roots", "set", taskID], expectedStatus: 2), code: "invalid_argument")
        let unchanged = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(unchanged?["roots"] as? [String], expectedRoots)
        attachScreenshot(named: "Edited ordered folders in task conversation")
    }

    // case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | Deleting a task removes it from the board and future lookup returns not found.
    func test_task_delete_removes_task_and_later_lookup_is_not_found() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Delete me", roots: ["primary"])
        let taskID = try taskID(named: "Delete me")
        let card = app.buttons["Delete me"]
        card.rightClick()
        let deleteAction = element("delete-task-menu-item")
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "The task context menu has no delete action.")
        deleteAction.click()
        let confirmation = element("confirm-delete-task-button")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        XCTAssertEqual(element("task-count").value as? String, "0")

        assertCLIError(try runCLI(["task", "get", taskID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Deleted task removed from the board")
    }

    // case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected.
    func test_default_parent_settings_read_write_clear_and_validation() throws {
        launchApp(defaultParent: nil)
        let initialSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(initialSettings?["defaultParentFolder"] as? String)

        element("new-task-button").click()
        let firstRunPanel = openFolderPanel
        XCTAssertTrue(firstRunPanel.waitForExistence(timeout: 10))
        firstRunPanel.buttons["Cancel"].click()
        XCTAssertEqual(element("task-count").value as? String, "0", "Cancelling the first-run picker must not create a task.")

        element("new-task-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        XCTAssertTrue(element("create-task-button").waitForExistence(timeout: 5))
        element("cancel-task-button").click()

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let chooseParent = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "choose-default-parent-folder-button").firstMatch
        XCTAssertTrue(chooseParent.waitForExistence(timeout: 10))
        chooseParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.alternateParent, confirmationButton: "Use This Folder")
        assertText("default-parent-folder-path", equals: fixture.alternateParent.path)
        let saved = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(saved?["defaultParentFolder"] as? String, fixture.alternateParent.path)

        assertCLIError(
            try runCLI(["settings", "set-parent", fixture.missing.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertText("default-parent-folder-path", equals: fixture.alternateParent.path)
        preferencesWindow.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch.click()
        let cleared = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(cleared?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        attachScreenshot(named: "Workspace settings can be changed and cleared")
    }

    // case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | Suggestions include top-level Git roots and skip nested repositories and symlink targets.
    func test_repository_suggestions_skip_nested_repositories_and_symlinks() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskSheet()
        for name in ["primary", "secondary", "alternate"] {
            XCTAssertTrue(element("repository-suggestion-\(name)").waitForExistence(timeout: 10), "Missing \(name) repository suggestion.")
        }
        XCTAssertFalse(element("repository-suggestion-nested").exists)
        XCTAssertFalse(element("repository-suggestion-linked-outside").exists)

        let result = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        XCTAssertEqual(
            result?["repositories"] as? [String],
            [fixture.primary.path, fixture.secondary.path, fixture.alternate.path].sorted()
        )
        assertScreenshotIfVisible(named: "Repository suggestions exclude nested and symlinked folders")
    }

    // case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    func test_task_roots_remain_after_default_parent_is_cleared() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Roots survive settings", roots: ["primary", "secondary"])
        openTask(named: "Roots survive settings")
        assertOrderedRoots([fixture.primary.path, fixture.secondary.path])
        app.buttons["back-to-board-button"].click()

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let clearParent = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch
        XCTAssertTrue(clearParent.waitForExistence(timeout: 10))
        clearParent.click()
        let clearedSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(clearedSettings?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        app.typeKey("w", modifierFlags: .command)

        openTask(named: "Roots survive settings")
        assertOrderedRoots([fixture.primary.path, fixture.secondary.path])
        let settings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(settings?["defaultParentFolder"] as? String)
        let roots = try runCLI(["task", "roots", "get", try taskID(named: "Roots survive settings")])["result"] as? [String: Any]
        XCTAssertEqual(roots?["roots"] as? [String], [fixture.primary.path, fixture.secondary.path])
        attachScreenshot(named: "Existing task roots survive clearing the default parent")
    }

    // case-contract: test_new_task_has_empty_conversation_history | A newly created task shows an empty conversation and has no stored messages or activity.
    func test_new_task_has_empty_conversation_history() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Empty conversation", roots: ["primary"])
        openTask(named: "Empty conversation")
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Start a conversation"].exists)

        let history = try runCLI(["conversation", "history", taskID(named: "Empty conversation")])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertNil(history?["diff"])
        attachScreenshot(named: "New conversation shows its empty state")
    }

    // case-contract: test_blank_conversation_send_is_rejected_without_starting_a_turn | Blank messages cannot be sent and do not create conversation history.
    func test_blank_conversation_send_is_rejected_without_starting_a_turn() throws {
        launchApp(defaultParent: fixture.parent.path)
        createTaskThroughUI(title: "Blank message", roots: ["primary"])
        openTask(named: "Blank message")
        let composer = element("message-composer")
        let sendButton = element("send-message-button")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(sendButton.isEnabled)
        composer.click()
        composer.typeText("   ")
        XCTAssertFalse(sendButton.isEnabled, "Whitespace-only messages must not be sent.")

        let taskID = try taskID(named: "Blank message")
        assertCLIError(
            try runCLI(["conversation", "send", taskID, "--message", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        attachScreenshot(named: "Blank composer leaves send disabled")
    }

    private func launchApp(defaultParent: String?) {
        app = XCUIApplication()
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        app.launchEnvironment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = defaultParent ?? "__unset__"
        app.launch()
        app.activate()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15))
    }

    private func relaunchApp() {
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15))
    }

    private func openNewTaskSheet() {
        element("new-task-button").click()
        XCTAssertTrue(element("task-title-field").waitForExistence(timeout: 10))
    }

    private func createTaskThroughUI(title: String, roots: [String]) {
        openNewTaskSheet()
        let titleField = element("task-title-field")
        titleField.click()
        titleField.typeText(title)
        for name in roots {
            let suggestion = element("repository-suggestion-\(name)")
            XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No repository suggestion for \(name).")
            suggestion.click()
        }
        let createButton = element("create-task-button")
        XCTAssertTrue(createButton.isEnabled, "A valid task title and roots should enable Done.")
        createButton.click()
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 10), "Created task is not on the board.")
    }

    private func openTask(named title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Task card is missing: \(title)")
        card.click()
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
    }

    private func assertTaskVisible(_ title: String, inColumn status: String) {
        let column = element("column-\(status.lowercased().replacingOccurrences(of: " ", with: "-"))")
        XCTAssertTrue(column.waitForExistence(timeout: 5), "Missing \(status) column.")
        XCTAssertTrue(column.buttons[title].waitForExistence(timeout: 8), "\(title) is not in \(status).")
    }

    private func dragTask(_ title: String, to status: String) {
        let card = app.buttons[title]
        let destination = element("column-\(status.lowercased().replacingOccurrences(of: " ", with: "-"))")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        let sourcePoint = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destinationPoint = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        sourcePoint.press(forDuration: 0.8, thenDragTo: destinationPoint)
    }

    private func assertOrderedRoots(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        let summary = element("working-folders-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Working folder summary is missing.", file: file, line: line)
        let text = [summary.label, summary.value as? String ?? "", summary.placeholderValue ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var searchStart = text.startIndex
        for path in paths {
            XCTAssertEqual(
                text.components(separatedBy: path).count - 1,
                1,
                "Folder selection should contain each root once.",
                file: file,
                line: line
            )
            guard let range = text.range(of: path, range: searchStart..<text.endIndex) else {
                XCTFail("Folders are missing or out of order: \(text)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }

    private var openFolderPanel: XCUIElement {
        app.windows.matching(identifier: "open-panel").firstMatch
    }

    private func chooseFolder(in panel: XCUIElement, folder: URL, confirmationButton: String) throws {
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The system folder panel did not open.")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5), "Go to Folder did not open from the system panel.")
        let pathField = goToSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(folder.standardizedFileURL.path)
        pathField.typeKey(.return, modifierFlags: [])
        let location = panel.descendants(matching: .any).matching(identifier: "where popup").firstMatch
        let locationExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", folder.lastPathComponent),
            object: location
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [locationExpectation], timeout: 10),
            .completed,
            "Folder panel did not navigate to \(folder.path)."
        )
        let chooseButton = panel.buttons[confirmationButton]
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 10), "Folder panel did not show \(confirmationButton).")
        chooseButton.click()
    }

    private var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
    }

    private func assertText(
        _ identifier: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(identifier)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", expected, expected),
            object: target
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Unexpected text for \(identifier): label=\(target.label), value=\(String(describing: target.value))",
            file: file,
            line: line
        )
    }

    private func tasksFromBoardList() throws -> [[String: Any]] {
        let response = try runCLI(["board", "list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["tasks"] as? [[String: Any]])
    }

    private func taskRecord(named title: String) throws -> [String: Any]? {
        try tasksFromBoardList().first { $0["title"] as? String == title }
    }

    private func taskID(named title: String) throws -> String {
        let record = try XCTUnwrap(taskRecord(named: title), "No task named \(title) exists in the real store.")
        return try XCTUnwrap(record["id"] as? String)
    }

    private func runCLI(_ arguments: [String], expectedStatus: Int32 = 0) throws -> [String: Any] {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, expectedStatus, "CLI \(arguments) exited unexpectedly: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last, "CLI returned no JSON for \(arguments)")
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any],
            "CLI response was not a JSON object."
        )
        XCTAssertEqual(response["version"] as? Int, 1)
        return response
    }

    private func assertCLIError(
        _ response: [String: Any],
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, code, file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertScreenshotIfVisible(named name: String) {
        attachScreenshot(named: name)
    }

    private static func findAppBundle() throws -> URL {
        var directory = Bundle(for: StationAIUITests.self).bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("StationAI.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "StationAIUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't locate the app bundle beside the UI test runner."
        ])
    }
}

private struct WorkspaceFixture {
    static let root = URL(fileURLWithPath: "/tmp/stationai-bridge-workspaces", isDirectory: true)
    static let ownerMarker = ".stationai-bridge-fixture"
    static let ownerContents = "StationAI bridge tests own this deterministic fixture (v1).\n"

    let parent: URL
    let primary: URL
    let secondary: URL
    let alternate: URL
    let alternateParent: URL
    let custom: URL
    let missing: URL
    let nested: URL
    let linkedOutside: URL

    static func load() throws -> WorkspaceFixture {
        let marker = root.appendingPathComponent(ownerMarker)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8), contents == ownerContents else {
            throw NSError(domain: "StationAIUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The deterministic Git fixtures are missing or not owned by StationAI. Run scripts/test-e2e.sh first."
            ])
        }
        let parent = root.appendingPathComponent("suggested-parent", isDirectory: true)
        let locations: [String: URL] = [
            "parent": parent,
            "primary": parent.appendingPathComponent("primary", isDirectory: true),
            "secondary": parent.appendingPathComponent("group/secondary", isDirectory: true),
            "alternateParent": parent.appendingPathComponent("alternate-parent", isDirectory: true),
            "alternate": parent.appendingPathComponent("alternate-parent/alternate", isDirectory: true),
            "custom": parent.appendingPathComponent("custom-folder", isDirectory: true),
            "nested": parent.appendingPathComponent("primary/nested", isDirectory: true),
            "linkedOutside": parent.appendingPathComponent("linked-outside", isDirectory: true)
        ]
        for (name, url) in locations where name != "linkedOutside" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "StationAIUITests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Missing \(name) fixture folder at \(url.path)."
                ])
            }
        }
        return WorkspaceFixture(
            parent: parent,
            primary: locations["primary"]!,
            secondary: locations["secondary"]!,
            alternate: locations["alternate"]!,
            alternateParent: locations["alternateParent"]!,
            custom: locations["custom"]!,
            missing: parent.appendingPathComponent("missing", isDirectory: true),
            nested: locations["nested"]!,
            linkedOutside: locations["linkedOutside"]!
        )
    }
}

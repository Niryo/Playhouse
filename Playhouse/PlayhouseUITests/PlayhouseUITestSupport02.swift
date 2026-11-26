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
    /// A case launched without a folder starts with the fixture's parent, so the Suggestions
    /// from prompt, which can't be dismissed, doesn't open at launch; this clears it once the
    /// board shows. The prompt's own case keeps it.
    var clearsParentAfterLaunch: Bool { launchDefaultParent == nil && !keepsSuggestionsFolderPrompt }
    private func clearLaunchParentIfNeeded() {
        guard clearsParentAfterLaunch else { return }
        XCTAssertNoThrow(try runCLI(["settings", "clear-parent"]))
    }
    func waitForBoardOrAbortSuite() {
        let boardTitle = element("board-title")
        if waitUntil({ self.isPlayhouseFrontmost }, timeout: 3),
           boardTitle.waitToExist(timeout: 6) {
            clearLaunchParentIfNeeded()
            return
        }

        let relaunchedAfterMissingWindow: Bool
        if terminateAppAndWait(app, timeout: 8) {
            launchAppWithOpen()
            relaunchedAfterMissingWindow = boardTitle.waitToExist(timeout: 8)
        } else {
            relaunchedAfterMissingWindow = false
        }

        let expectedBundleID = Bundle(url: appBundle)?.bundleIdentifier ?? "unknown"
        let frontmostDescription = Self.frontmostApplicationDescription
        guard !relaunchedAfterMissingWindow else {
            clearLaunchParentIfNeeded()
            return
        }
        let reason = "Playhouse UI startup failed after a process restart recovery attempt. Expected frontmost app \(expectedBundleID); actual frontmost app: \(frontmostDescription); app state: \(app.state.rawValue); board title not found."
        Self.suiteAbortReason = reason
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Playhouse startup failure and frontmost app"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTFail(reason)
    }
    /// Drags the main window's right edge as far left as it goes, to the window's minimum
    /// width; the test screen otherwise opens it wide enough to fit every layout's content.
    /// Setup and teardown clear the saved frame, so later cases open at the usual size.
    func narrowWindowToMinimumWidth() {
        shrinkWindowToMinimum(width: true, height: false)
    }
    /// Drags the main window's bottom edge as far up as it goes, to the window's minimum height.
    func shortenWindowToMinimumHeight() {
        shrinkWindowToMinimum(width: false, height: true)
    }
    private func shrinkWindowToMinimum(width: Bool, height: Bool) {
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: width ? 1 : 0.5, dy: height ? 1 : 0.5))
            .withOffset(CGVector(dx: width ? -1 : 0, dy: height ? -1 : 0))
        edge.press(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: width ? -window.frame.width : 0, dy: height ? -window.frame.height : 0)))
    }
    func clearSavedWindowFrames() {
        guard let bundleIdentifier = Bundle(url: appBundle)?.bundleIdentifier,
              bundleIdentifier == "com.playhouse.app.e2e" || bundleIdentifier.hasPrefix("com.playhouse.app.e2e.") ||
                (bundleIdentifier.hasPrefix("com.playhouse.app.worktree.") && bundleIdentifier.contains(".e2e.")),
              let appDefaults = UserDefaults(suiteName: bundleIdentifier) else {
            return
        }
        let windowFrameKeys = appDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSWindow Frame ") }
        for key in windowFrameKeys {
            appDefaults.removeObject(forKey: key)
        }
        appDefaults.synchronize()
    }
    func makeCodexFixture(emptyQuestions: Bool, nonblocking: Bool = false) throws -> URL {
        let executable = WorkspaceFixture.root
            .appendingPathComponent(emptyQuestions ? "codex-fixture-empty" : (nonblocking ? "codex-fixture-nonblocking" : "codex-fixture-ui"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "The prepared Codex fixture is missing or not executable.")
        // The shared fixture records turns and hold markers beside itself; start each case
        // from an empty history and no holds, once, so a later call cannot remove a running
        // turn's. A failed assertion ends a case without its `defer`s, which would otherwise
        // leave an earlier case's hold to stall this one's turns.
        if codexFixtureHistoriesReset.insert(executable.path).inserted {
            for suffix in [".history", ".hold-release", ".outcome-hold", ".turn-active", ".turn-release"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + suffix))
            }
        }
        return executable
    }
    func makeGitHubStateFixture() throws -> [String: String] {
        try makeGitHubStateFixture(expectedNumbers: [123, 456])
    }
    /// PATH that resolves `git` to the staged hold wrapper first; see `GitHoldBarrier`.
    func makeGitHoldEnvironment() throws -> [String: String] {
        let directory = GitHoldBarrier.directory
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("git").path), "The prepared git hold wrapper is missing or not executable.")
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ["PATH": "\(directory.path):\(inheritedPath)"]
    }
    func makeGitHubStateFixture(expectedNumbers: [Int]) throws -> [String: String] {
        let directory = dataDirectory.appendingPathComponent("gh-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state")
        let callLogURL = directory.appendingPathComponent("calls")
        let createLogURL = directory.appendingPathComponent("create-calls")
        let detectLogURL = directory.appendingPathComponent("detect-calls")
        let createFailureURL = directory.appendingPathComponent("fail-create-attempt")
        try expectedNumbers.map { "\($0)=unmerged" }.joined(separator: "\n").appending("\n")
            .write(to: stateURL, atomically: true, encoding: .utf8)
        let startedDirectory = directory.appendingPathComponent("started", isDirectory: true)
        try FileManager.default.createDirectory(at: startedDirectory, withIntermediateDirectories: true)
        let expectedIDs = expectedNumbers.map(String.init).joined(separator: " ")
        // The runner stages scripts/fixtures/gh-fixture.sh as an executable named gh; the sandboxed
        // test process cannot write one itself without quarantine.
        let ghDirectory = WorkspaceFixture.root.appendingPathComponent("gh-fixture", isDirectory: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ghDirectory.appendingPathComponent("gh").path), "The prepared gh fixture is missing or not executable.")
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return [
            "PATH": "\(ghDirectory.path):\(inheritedPath)",
            "PLAYHOUSE_E2E_GH_STATE_PATH": stateURL.path,
            "PLAYHOUSE_E2E_GH_CALL_LOG": callLogURL.path,
            "PLAYHOUSE_E2E_GH_CREATE_LOG": createLogURL.path,
            "PLAYHOUSE_E2E_GH_DETECT_LOG": detectLogURL.path,
            "PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH": createFailureURL.path,
            "PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER": "501",
            "PLAYHOUSE_E2E_GH_STARTED_DIRECTORY": startedDirectory.path,
            "PLAYHOUSE_E2E_GH_EXPECTED_IDS": expectedIDs,
        ]
    }
    /// Every task with a started worktree and no pull request has the board probe look one
    /// up on GitHub, and `gh` resolves to /opt/homebrew/bin/gh when PATH has none. A case
    /// that set up no gh fixture of its own gets one that knows no pull requests, in a
    /// directory of its own so it never resets a case's `gh-fixture` state on relaunch.
    func addDefaultGitHubFixture(to environment: inout [String: String]) {
        let ghDirectory = WorkspaceFixture.root.appendingPathComponent("gh-fixture", isDirectory: true).path
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        if !path.split(separator: ":").contains(Substring(ghDirectory)) {
            environment["PATH"] = "\(ghDirectory):\(path)"
        }
        guard environment["PLAYHOUSE_E2E_GH_STATE_PATH"] == nil else { return }
        let directory = dataDirectory.appendingPathComponent("gh-default", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state")
        if !FileManager.default.fileExists(atPath: stateURL.path) {
            FileManager.default.createFile(atPath: stateURL.path, contents: Data())
        }
        environment["PLAYHOUSE_E2E_GH_STATE_PATH"] = stateURL.path
        environment["PLAYHOUSE_E2E_GH_CALL_LOG"] = directory.appendingPathComponent("calls").path
        environment["PLAYHOUSE_E2E_GH_CREATE_LOG"] = directory.appendingPathComponent("create-calls").path
        environment["PLAYHOUSE_E2E_GH_DETECT_LOG"] = directory.appendingPathComponent("detect-calls").path
    }
    func activateOtherAppThenReturn() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        app.activate()
    }
    /// Stops this case's own fixture provider (its path is unique to the case) so the next send
    /// relaunches it and resumes the thread, as after a provider restart. Mirrors the CLI suite's
    /// `restart_provider`.
    func restartProvider(_ executable: URL) throws {
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stop.arguments = ["-f", executable.path]
        try stop.run()
        stop.waitUntilExit()
        // In the VM the runner's pkill and pgrep don't reach a shared Codex app-server the
        // daemon started, so it is also stopped through the pid its manifest records.
        let resolved = executable.resolvingSymlinksInPath().path
        let servers = agentManifests().compactMap { entry -> [String: Any]? in
            guard entry.kind == "codex", entry.manifest["resolvedExecutablePath"] as? String == resolved,
                  let process = entry.manifest["process"] as? [String: Any], agentIsAlive(process) else { return nil }
            return process
        }
        for server in servers {
            if let pid = (server["pid"] as? NSNumber)?.int32Value { kill(pid, SIGTERM) }
        }
        XCTAssertTrue(waitUntil({ servers.allSatisfy { !self.agentIsAlive($0) } }, timeout: 10),
                      "The fixture's Codex app-server should stop: \(executable.path)")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            probe.arguments = ["-f", executable.path]
            probe.standardOutput = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("The fixture provider did not stop: \(executable.path)")
    }
    func relaunchApp() {
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before the resume-path relaunch.")
        launchAppWithOpen()
        waitForBoardOrAbortSuite()
    }
    func terminateAppAndWait(_ target: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        guard target.state != .notRunning else {
            return true
        }
        target.terminate()
        return waitUntil({ target.state == .notRunning }, timeout: timeout)
    }
    func openNewTaskConversation() {
        app.activate()
        element("new-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitToExist(timeout: 10), "New Task should create and open an empty conversation.")
        XCTAssertFalse(element("conversation-repository-search").exists, "A new conversation should keep its repository picker closed.")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10), "A new conversation should focus the chat composer.")
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(composer.value as? String, "x", "The chat composer should receive keyboard input immediately.")
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertEqual(composer.value as? String, "", "The focus check should leave the new composer empty.")
        XCTAssertFalse(element("create-task-button").exists, "Direct creation should not show the New Task sheet.")
    }
    func closeConversationRepositoryPicker() {
        guard element("conversation-repository-search").exists else { return }
        element("add-conversation-repository-button").click()
        XCTAssertTrue(waitUntil({ !self.element("conversation-repository-search").exists }, timeout: 5), "The conversation repository picker should close.")
    }
    /// Clicks a text field once it has settled, confirms it took keyboard focus
    /// (retrying the click once), then types. A click that lands while the
    /// form is still scrolling into place can leave the field unfocused, and
    /// typeText then fails with "Neither element nor any descendant has
    /// keyboard focus".
    func typeIntoField(_ field: XCUIElement, text: String, file: StaticString = #filePath, line: UInt = #line) {
        focusField(field, file: file, line: line)
        field.typeText(text)
    }
    /// The focusing half of `typeIntoField`, for a caller that types keys of its own next.
    func focusField(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitToExist(timeout: 5), "Text field is missing.", file: file, line: line)
        waitForStableFrame(field)
        field.click()
        if !waitUntil({ (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }, timeout: 2) {
            field.click()
            XCTAssertTrue(waitUntil({ (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }, timeout: 2), "Clicking the text field should focus it.", file: file, line: line)
        }
    }
    /// Selects a question option once the form has settled. The question form
    /// arrives with a transcript reload that scrolls it; a click issued the
    /// moment the title exists can land before the option is in place, leaving
    /// nothing selected and a Submit click that does nothing.
    func selectQuestionOption(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        selectQuestionOption(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch, named: label, file: file, line: line)
    }
    /// The same, for an option named by its accessibility identifier, where
    /// several questions in one form offer the same label.
    func selectQuestionOption(identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        selectQuestionOption(element(identifier), named: identifier, file: file, line: line)
    }
    func selectQuestionOption(_ option: XCUIElement, named label: String, file: StaticString, line: UInt) {
        XCTAssertTrue(option.waitToExist(timeout: 5), "Question option is missing: \(label)", file: file, line: line)
        XCTAssertTrue(waitForStableFrame(option), "Question option should settle in place: \(label)", file: file, line: line)
        XCTAssertTrue(revealInConversation(option), "Question option should be scrolled into the conversation's visible area: \(label)", file: file, line: line)
        option.click()
        XCTAssertTrue(
            waitUntil({ option.value as? String == "selected" }, timeout: 3),
            "Clicking the question option should select it: \(label)", file: file, line: line
        )
    }
    /// Scrolls the conversation until `target` lies inside its visible area. The transcript
    /// follows its newest content, so a layout change below a question form (a queued
    /// follow-up bar, a live activity row) can push the form's first options above the
    /// viewport, where a click lands on the header instead. True once it is fully visible.
    func revealInConversation(_ target: XCUIElement) -> Bool {
        reveal(target, in: element("conversation-scroll-view"))
    }
    /// Scrolls `scrollView` until `target` lies inside its visible area: a pointer sent to a row
    /// clipped at the edge lands on whatever is drawn there. True once it is fully visible.
    func reveal(_ target: XCUIElement, in scrollView: XCUIElement) -> Bool {
        guard scrollView.exists else { return true }
        for _ in 0..<8 {
            guard target.exists else { return false }
            let viewport = scrollView.frame
            let frame = target.frame
            if frame.minY >= viewport.minY && frame.maxY <= viewport.maxY { return true }
            if frame.minY < viewport.minY {
                scrollView.scroll(byDeltaX: 0, deltaY: min(200, viewport.minY - frame.minY + 24))
            } else {
                scrollView.scroll(byDeltaX: 0, deltaY: -min(200, frame.maxY - viewport.maxY + 24))
            }
            _ = waitForStableFrame(target, timeout: 2)
        }
        let viewport = scrollView.frame
        return target.exists && target.frame.minY >= viewport.minY && target.frame.maxY <= viewport.maxY
    }
    /// Waits until `target`'s frame has stopped changing for 0.4 s. A click sent the instant a
    /// control appears can land where the control was a frame earlier.
    @discardableResult
    func waitForStableFrame(_ target: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        var previous = CGRect.null
        var stableSince = Date()
        return waitUntil({
            // A lazy transcript row can leave the hierarchy while it scrolls; a missing element's
            // frame read fails hard, so it is read from a snapshot and is simply not stable yet.
            guard let frame = (try? target.snapshot())?.frame else { previous = .null; stableSince = Date(); return false }
            if frame != previous { previous = frame; stableSince = Date() }
            return !frame.isEmpty && Date().timeIntervalSince(stableSince) >= 0.4
        }, timeout: timeout)
    }
    /// Opens a slide-up panel (skills, rules, MCP) with one click on `control`
    /// and waits for it to finish sliding in, so the next click lands on a
    /// control that has stopped moving. One click must be enough, including
    /// right after another panel closed: a closed panel's overlay must not catch
    /// clicks, even while its scrim is still fading out.
    func openPanel(_ identifier: String, with control: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let panel = element(identifier)
        control.click()
        return panel.waitToExist(timeout: timeout) && waitForStableFrame(panel)
    }
    /// The composer saves the task (which shows its chips) before it writes the remembered
    /// repositories, so a chip appearing does not mean the setting is saved yet. Waits for the
    /// saved value instead of reading it once.
    func assertLastSelectedRepositories(
        _ expected: [String],
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var saved: [String]?
        let settled = waitUntil({
            saved = (try? self.runCLI(["settings", "get"])["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String]
            return saved == expected
        }, timeout: timeout)
        XCTAssertTrue(settled, "lastSelectedRepositories should become \(expected), last read \(String(describing: saved)).", file: file, line: line)
    }
    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
    func isolatedPreferenceKeys() -> Set<String> {
        guard let data = try? Data(contentsOf: isolatedPreferencesFile),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        return Set(values.keys)
    }
    /// The stored draft state of a task, for failure messages.
    func draftStateSummary(_ id: String) -> String {
        let record = (try? taskRecord(id: id)) ?? nil
        return "status=\(String(describing: record?["status"])) hasUnsentDraft=\(String(describing: record?["hasUnsentDraft"])) savedPrompt=\(String(describing: record?["savedPrompt"])) pending=\(String(describing: record?["pendingSubmittedPrompt"]))"
    }
    func createTaskFixture(title: String, roots: [String]) throws {
        var arguments = ["task", "create", "--title", title, "--prompt", "Fixture task description."]
        for root in roots { arguments += ["--root", root] }
        let result = try runCLI(arguments)["result"] as? [String: Any]
        XCTAssertEqual(result?["title"] as? String, title)
    }
    func saveNewTaskPromptAndReturnToBoard(_ title: String, prompt: String? = nil) {
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The direct-created task should expose its conversation composer.")
        composer.click()
        composer.typeText(prompt ?? title)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10), "Returning to the board should preserve the automatically saved prompt.")
        guard let task = try? tasksFromBoardList().first, let taskID = task["id"] as? String else {
            XCTFail("The created task should remain in Backlog after saving its prompt.")
            return
        }
        _ = try? runCLI(["task", "rename", taskID, "--title", title])
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["title"] as? String) == title
                && app.buttons[title].exists
        }, timeout: 10), "The created task should be visible with its deterministic test title.")
    }
    func chooseRepositorySuggestion(_ name: String) {
        var searchField = element("conversation-repository-search")
        if !searchField.exists {
            element("add-conversation-repository-button").click()
            searchField = element("conversation-repository-search")
        }
        XCTAssertTrue(searchField.waitToExist(timeout: 5), "The conversation picker should be open before choosing a repository.")
        searchField.click()
        replaceText(searchField, with: name)
        let suggestion = element("conversation-repository-suggestion-\(name)")
        XCTAssertTrue(suggestion.waitToExist(timeout: 10), "No repository suggestion for \(name).")
        XCTAssertTrue(suggestion.isHittable, "Repository suggestion \(name) should be reachable in the scrolling picker.")
        suggestion.click()
        XCTAssertTrue(element("conversation-repository-badge-\(name)").waitToExist(timeout: 10), "The selected repository should appear in the conversation header.")
    }
    func setConversationRepositoryField(_ repositoryName: String, field: String, value: String) {
        let badge = element("conversation-repository-badge-\(repositoryName)")
        XCTAssertTrue(badge.waitToExist(timeout: 5), "The conversation should show \(repositoryName) before editing its settings.")
        badge.click()
        let edit = element("conversation-repository-\(field)-edit")
        XCTAssertTrue(edit.waitToExist(timeout: 5), "The conversation repository settings should expose the \(field) edit control.")
        edit.click()
        let fieldElement = element("conversation-repository-\(field)")
        XCTAssertTrue(fieldElement.waitToExist(timeout: 5))
        replaceText(fieldElement, with: value)
        element("conversation-repository-\(field)-save").click()
        XCTAssertTrue(waitUntil({
            guard let task = try? self.tasksFromBoardList().first,
                  let records = task["repositoryWorktrees"] as? [[String: Any]],
                  let record = records.first(where: {
                      guard let path = $0["repositoryPath"] as? String else { return false }
                      return URL(fileURLWithPath: path).lastPathComponent == repositoryName
                  }) else {
                return false
            }
            let key = field == "branch" ? "branch" : (field == "branch-from" ? "branchFrom" : "mergeTarget")
            return record[key] as? String == value
        }, timeout: 10), "The conversation should persist the edited \(field) value.")

        // The settings popover stays open after a save, so close it before the next step.
        XCTAssertTrue(waitForDisappearance(fieldElement), "A saved value should leave edit mode.")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(edit), "Escape should close the repository settings.")
    }
    func pasteText(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
    }
    func replaceText(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }
    /// Leaves the open task for the board. Right after a turn ends the back
    /// button can be re-rendered and swallow a click, so wait for it to be
    /// hittable and confirm the board actually appeared.
    func returnToBoard() {
        let backToBoard = element("back-to-board-button")
        XCTAssertTrue(waitUntil({ backToBoard.isHittable }, timeout: 5), "The back-to-board button never became clickable.")
        XCTAssertTrue(waitForStableFrame(backToBoard), "The back-to-board button kept moving.")
        backToBoard.click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5), "Clicking back-to-board should show the board.")
    }
    func openTask(named title: String, horizontalRecovery: Bool = false) {
        // Task cards are only on the board; leave an open task first. The back
        // button can be briefly non-hittable right after a send (tooltip,
        // re-render), so wait for it instead of silently staying in the task.
        let backToBoard = element("back-to-board-button")
        let boardTitle = element("board-title")
        if backToBoard.exists || (!boardTitle.exists && backToBoard.waitToExist(timeout: 2)) {
            // A caller may already be mid-transition to the board (it clicked
            // back itself); then the lingering button never becomes hittable
            // and the board arriving is the success case.
            XCTAssertTrue(waitUntil({ boardTitle.exists || backToBoard.isHittable }, timeout: 5), "Neither the board nor a clickable back-to-board button appeared.")
            if !boardTitle.exists {
                backToBoard.click()
                XCTAssertTrue(boardTitle.waitToExist(timeout: 5))
            }
        }
        let card = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 10), "Task card is missing: \(title)")
        if !card.isHittable {
            let board = element("board-columns-scroll-view")
            if horizontalRecovery {
                for _ in 0..<6 {
                    guard !card.isHittable else { break }
                    board.swipeLeft()
                }
                for _ in 0..<6 {
                    guard !card.isHittable else { break }
                    board.swipeRight()
                }
            }
            for _ in 0..<12 {
                guard !card.isHittable else { break }
                board.scroll(byDeltaX: 0, deltaY: -300)
                board.swipeUp()
            }
        }
        let useCoordinateFallback = horizontalRecovery && !card.isHittable
        if !useCoordinateFallback {
            XCTAssertTrue(card.isHittable, "Task card must be hittable after bounded board scrolling.")
        }
        clickTaskCardTitle(card)
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10), "Clicking the task card title should open the task.")
        waitForConversationLoad()
    }
    /// The history, pending question and unsent draft land after the task view
    /// appears; reading or scrolling the transcript before then sees an empty task.
    func waitForConversationLoad(file: StaticString = #filePath, line: UInt = #line) {
        let transcript = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({ transcript.exists && transcript.value as? String != "Loading conversation history" }, timeout: 15),
                      "The opened conversation's history should finish loading.", file: file, line: line)
    }
    /// Scrolls the board's columns sideways until `target` lies fully inside the
    /// visible board. With the persistent sidebar, a narrow screen (the UI VM's is
    /// 1024 points) clips the Review column's trailing edge, where a card's PR
    /// controls sit: they stay in the hierarchy but take no hover or click.
    func revealOnBoard(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let board = element("board-columns-scroll-view")
        XCTAssertTrue(target.waitToExist(timeout: 5), "Board control is missing: \(target.identifier)", file: file, line: line)
        // A negative delta moves the columns left, revealing content on the right;
        // flip it once if a step moved the control the wrong way.
        var direction: CGFloat = -1
        for _ in 0..<8 {
            let visible = board.frame, frame = target.frame
            if visible.contains(frame) { break }
            let overflow = frame.maxX > visible.maxX ? frame.maxX - visible.maxX + 24 : frame.minX - visible.minX - 24
            board.scroll(byDeltaX: direction * overflow, deltaY: 0)
            waitForStableFrame(target, timeout: 2)
            let moved = target.frame.minX - frame.minX
            if moved == 0 || (moved > 0) == (overflow > 0) { direction = -direction }
        }
        XCTAssertTrue(board.frame.contains(target.frame), "\(target.identifier) should be scrolled into the visible board; control=\(target.frame), board=\(board.frame).", file: file, line: line)
    }
    /// Opens a board card through its title. The card's center can sit on one
    /// of its own controls (the token counter button opens Token stats), so a
    /// plain card.click() may open that control instead of the task.
    func clickTaskCardTitle(_ card: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let cardTitle = element(card.identifier.replacingOccurrences(of: "task-card-", with: "task-title-"))
        XCTAssertTrue(cardTitle.waitToExist(timeout: 5), "Task card title is missing: \(card.identifier)", file: file, line: line)
        let titleCenter = CGPoint(x: cardTitle.frame.midX, y: cardTitle.frame.midY)
        XCTAssertTrue(card.frame.contains(titleCenter), "Task card title must lie inside the visible card.", file: file, line: line)
        cardTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
    func completeCurrentTaskWithFixtureAnswers(
        taskTitle: String,
        prompt: String = "Complete this task.",
        reportCompletedOutcome: Bool = true,
        expectedFinalStatus: String? = nil,
        settleTimeout: TimeInterval = 10,
        whileTurnHeld: (() throws -> Void)? = nil,
        reloadConversationAfterTurn: Bool = false
    ) throws {
        let taskID = try taskID(named: taskTitle)
        let executablePath = try XCTUnwrap(codexFixtureExecutable, "The task fixture has no Codex executable.")
        let hold = URL(fileURLWithPath: executablePath + ".outcome-hold")
        let active = URL(fileURLWithPath: executablePath + ".outcome-active")
        let release = URL(fileURLWithPath: executablePath + ".outcome-release")
        try? FileManager.default.removeItem(at: active)
        try? FileManager.default.removeItem(at: release)
        try Data().write(to: hold, options: .atomic)
        defer {
            try? "Release the answered fixture turn.\n".write(to: release, atomically: true, encoding: .utf8)
            _ = waitUntil({ !FileManager.default.fileExists(atPath: active.path) }, timeout: 10)
            try? FileManager.default.removeItem(at: hold)
            try? FileManager.default.removeItem(at: active)
            try? FileManager.default.removeItem(at: release)
        }
        element("message-composer").click()
        element("message-composer").typeText(prompt)
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitToExist(timeout: 10))
        selectQuestionOption("Blue")
        typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: active.path) }, timeout: 10), "The fixture should hold after receiving answers so the task outcome can be reported.")
        try whileTurnHeld?()
        if reportCompletedOutcome {
            XCTAssertTrue(waitUntil({
                (try? self.taskRecord(id: taskID)?["status"] as? String) == "In Progress"
            }, timeout: 10), "The task should be In Progress before reporting the fixture outcome.")
            let outcome = try runCLI(["task", "outcome", taskID, "completed"])
            XCTAssertEqual((outcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
        }
        try "Release the answered fixture turn.\n".write(to: release, atomically: true, encoding: .utf8)
        if reloadConversationAfterTurn {
            openTask(named: taskTitle)
        }
        let answer = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "assistant-message-",
                "Answers received: Blue / fixture-secret."
            )
        ).firstMatch
        XCTAssertTrue(answer.waitToExist(timeout: 10))
        let expectedStatus = expectedFinalStatus ?? (reportCompletedOutcome ? "Review" : "Waiting Response")
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == expectedStatus
        }, timeout: settleTimeout), "The completed turn should settle in \(expectedStatus).")
        // Review is written before the turn finishes: it still creates the PR the task's mode asks
        // for, and the turn is over only once it releases the task's reservation. Other expected
        // statuses can hand straight on to a follow-up turn (autopilot's fix turn takes the same
        // reservation), so only a turn that ends in Review is waited out here.
        if expectedStatus == "Review" {
            XCTAssertTrue(waitUntil({
                !ConversationTurnLockBarrier.isHeldByAnotherProcess(dataDirectory: self.dataDirectory, taskID: taskID)
            }, timeout: settleTimeout), "The completed turn should release its conversation-turn reservation.")
        }
    }
    func assertTaskVisible(_ title: String, inColumn status: String) {
        // Board columns are only on the board; leave an open task first.
        let backToBoard = element("back-to-board-button")
        if backToBoard.exists, backToBoard.isHittable {
            backToBoard.click()
            XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        }
        let column = element("column-\(status.lowercased().replacingOccurrences(of: " ", with: "-"))")
        XCTAssertTrue(column.waitToExist(timeout: 5), "Missing \(status) column.")
        XCTAssertTrue(column.buttons[title].waitToExist(timeout: 8), "\(title) is not in \(status).")
    }
    func assertTaskArchived(_ title: String) throws {
        let taskID = try taskID(named: title)
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitToExist(timeout: 10), "\(title) should appear in the completed task archive.")
        element("close-done-archive-button").click()
    }
    func moveTaskToDone(_ title: String) {
        let card = app.buttons[title].firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 5))
        dragTaskToDone(card)
        XCTAssertTrue(waitUntil({
            do { return try taskRecord(named: title)?["status"] as? String == "Done" }
            catch { return false }
        }, timeout: 15), "Dropping \(title) on the Done target should persist its Done status.")
    }
    func moveTaskToDone(taskID: String) {
        let card = element("task-card-\(taskID)").firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 5), "The reviewed task card should remain available by its stable task identifier.")
        dragTaskToDone(card)
        XCTAssertTrue(waitUntil({
            do { return try taskRecord(id: taskID)?["status"] as? String == "Done" }
            catch { return false }
        }, timeout: 15), "Dropping task \(taskID) on the Done target should persist its Done status.")
    }
    func dragTaskToDone(_ card: XCUIElement) {
        let board = element("board-columns-scroll-view")
        XCTAssertTrue(board.waitToExist(timeout: 5), "The board columns should remain visible while moving a task to Done.")
        XCTAssertTrue(element("task-done-drop-target").waitToExist(timeout: 5), "The Done drawer should always be present at the board edge.")
        let source = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // The drawer's tab slides open once the drag begins and is then centered 32 points
        // in from the board scroller's lane, which is about 16 points wide at the window edge.
        let doneTarget = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -48, dy: 0))
        source.press(forDuration: 0.5, thenDragTo: doneTarget, withVelocity: .default, thenHoldForDuration: 1.5)
    }
    /// Starts a full-screen capture that fires while a following blocking gesture is still
    /// in progress, so a mid-drag state can be attached once the gesture returns.
    func startDelayedScreenCapture(afterSeconds delay: Int) -> (process: Process, file: URL)? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("playhouse-capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-T", "\(delay)", file.path]
        do {
            try process.run()
            return (process, file)
        } catch {
            return nil
        }
    }
    func attachScreenCapture(_ capture: (process: Process, file: URL)?, named name: String) {
        guard let capture else { return }
        capture.process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: capture.file) }
        guard FileManager.default.fileExists(atPath: capture.file.path) else { return }
        let attachment = XCTAttachment(contentsOfFile: capture.file)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// The Done drawer shows only a thin sliver beside the columns while nothing is dragged,
    /// just left of the board's vertical scroller, which keeps the window edge.
    func assertDoneDrawerResting(_ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        let drawer = element("task-done-drop-target")
        let board = element("board-columns-scroll-view")
        let lastColumn = element("column-review")
        let window = app.windows.firstMatch
        XCTAssertTrue(drawer.waitToExist(timeout: 5), "The Done drawer should exist \(moment).", file: file, line: line)
        // In a window narrower than the columns the board scrolls sideways, and the gutter left
        // for the drawer clears the last column once the board is scrolled to its trailing end.
        for _ in 0..<10 {
            guard lastColumn.frame.maxX > drawer.frame.minX else { break }
            board.scroll(byDeltaX: -400, deltaY: 0)
        }
        // The sliver is 5 points wide and sits left of a scroller lane of 11 to 16 points.
        XCTAssertTrue(waitUntil({ drawer.frame.minX >= window.frame.maxX - 24 }, timeout: 3), "The Done drawer should rest as a sliver near the window edge \(moment).", file: file, line: line)
        XCTAssertLessThanOrEqual(drawer.frame.minX, window.frame.maxX - 14, "The Done drawer must leave the window edge to the board scroller \(moment).", file: file, line: line)
        XCTAssertGreaterThanOrEqual(board.frame.maxX, window.frame.maxX - 1, "The board, and so its vertical scroller, must reach the window edge \(moment).", file: file, line: line)
        // In a window narrower than the columns, the board scrolls sideways and the last column
        // reaches the drawer only at the end, where the board's trailing gutter keeps it clear.
        // The first delta may scroll the wrong way; the second then passes the start the right way.
        for delta in [-600.0, 1200.0] where lastColumn.frame.maxX > drawer.frame.minX {
            board.scroll(byDeltaX: delta, deltaY: 0)
            _ = waitForStableFrame(lastColumn)
        }
        XCTAssertGreaterThanOrEqual(drawer.frame.minX, lastColumn.frame.maxX, "The Done drawer must sit beside the board columns, never over them \(moment).", file: file, line: line)
    }
    /// Installs the Claude Code protocol fixture for this case and returns the
    /// environment a CLI-driven turn needs. Must run before `launchApp` so the
    /// app's own turns use it too.
    func installClaudeFixture(named name: String) throws -> [String: String] {
        ["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": try installClaudeFixtureExecutable(named: name).path]
    }
    /// Installs the OpenCode server fixture for this case and returns the environment a CLI-driven
    /// turn needs. Must run before `launchApp` so the app's own turns use it too.
    func installOpenCodeFixture(named name: String) throws -> [String: String] {
        let executable = dataDirectory.appendingPathComponent(name)
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("opencode-fixture-ui"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("Playhouse test owns this OpenCode protocol fixture (v1).\n".utf8).write(
            to: dataDirectory.appendingPathComponent(".playhouse-opencode-fixture-owner")
        )
        openCodeFixtureExecutable = executable.path
        return ["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": executable.path]
    }
    /// The usage dot is one flat hue, so the dominant channel says where on the
    /// green-to-red heatmap it currently sits. `leftEdgeFraction` restricts the
    /// sample to a left-hand slice of `element`'s screenshot — used to read the
    /// CPU bar's color off the stable task card instead of the thin animated
    /// bar sub-view itself, whose identity can transiently drop out of the
    /// accessibility tree between an existence check and a screenshot fetch.
    func isGreenDominant(_ element: XCUIElement, leftEdgeFraction: CGFloat = 1.0) -> Bool {
        guard element.exists else { return false }
        let image = element.screenshot().image
        return pixelCount(in: image, maxXFraction: leftEdgeFraction) { $0.greenComponent > $0.redComponent + 0.15 } > 4
    }
    func isRedDominant(_ element: XCUIElement, leftEdgeFraction: CGFloat = 1.0) -> Bool {
        guard element.exists else { return false }
        let image = element.screenshot().image
        return pixelCount(in: image, maxXFraction: leftEdgeFraction) { $0.redComponent > $0.greenComponent + 0.15 } > 4
    }
    func assertPixel(_ image: NSImage, normalizedX: CGFloat, normalizedY: CGFloat, rgb expected: (Int, Int, Int), accuracy: Int = 8, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read workspace screenshot pixels.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * normalizedX)))
        let y = min(cgImage.height - 1, max(0, Int(CGFloat(cgImage.height) * normalizedY)))
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Could not sample workspace background color.", file: file, line: line)
            return
        }
        XCTAssertEqual(Int((color.redComponent * 255).rounded()), expected.0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Int((color.greenComponent * 255).rounded()), expected.1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Int((color.blueComponent * 255).rounded()), expected.2, accuracy: accuracy, file: file, line: line)
    }
    func assertTrackThickness(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read effort slider pixels.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * 0.10)))
        var accentRows = 0
        for y in 0..<cgImage.height {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.blueComponent > 0.55 && color.blueComponent > color.redComponent * 1.2 {
                accentRows += 1
            }
        }
        let fraction = Double(accentRows) / Double(cgImage.height)
        XCTAssertGreaterThanOrEqual(fraction, 0.23,
            "The 6-point effort track should remain visibly thicker than the previous 4-point track (blue-pixel fraction: \(fraction)).",
            file: file, line: line)
    }
    func assertNoBlueFocusOutline(in image: NSImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read effort slider pixels.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // A focus border runs along every side; the filled track reaches the
        // left and right edges, so only the top and bottom edges are sampled.
        let edgePoints: [(CGFloat, CGFloat)] = (1...9).map { (CGFloat($0) / 10, 0.04) }
            + (1...9).map { (CGFloat($0) / 10, 0.96) }
        var bluePixels = 0
        for (normalizedX, normalizedY) in edgePoints {
            let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * normalizedX)))
            let y = min(cgImage.height - 1, max(0, Int(CGFloat(cgImage.height) * normalizedY)))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.blueComponent > 0.55 && color.blueComponent > color.redComponent * 1.4 {
                bluePixels += 1
            }
        }
        XCTAssertEqual(bluePixels, 0, "The focused effort slider should not draw a blue focus border.", file: file, line: line)
    }
    func assertContainsRedForeground(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let redPixels = pixelCount(in: element.screenshot().image, step: 2) {
            $0.redComponent > 0.65 && $0.greenComponent < 0.4 && $0.blueComponent < 0.4
        }
        XCTAssertGreaterThan(redPixels, 3, "The missing-folder warning should render red foreground pixels.", file: file, line: line)
    }
    func assertPlayhouseLogoArtwork(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let logoImage = element.screenshot().image
        guard logoImage.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            XCTFail("Could not read the Playhouse logo screenshot.", file: file, line: line)
            return
        }
        assertPixel(logoImage, normalizedX: 0.20, normalizedY: 0.50, rgb: (71, 176, 235), accuracy: 30, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.80, normalizedY: 0.50, rgb: (148, 41, 121), accuracy: 30, file: file, line: line)
        // The warm center sits in the stage's solid block; higher up it is a sliver that a 1x
        // screen renders as a blend with the magenta curtain beside it.
        assertPixel(logoImage, normalizedX: 0.50, normalizedY: 0.66, rgb: (245, 179, 124), accuracy: 35, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.20, normalizedY: 0.80, rgb: (177, 54, 171), accuracy: 35, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.80, normalizedY: 0.80, rgb: (240, 82, 121), accuracy: 30, file: file, line: line)
    }
    /// The activity section renders open while a turn runs and collapses once it
    /// settles, so a test that needs the details open must expand only when the
    /// disclosure is actually collapsed; clicking blindly can close it instead.
    /// Reports whether the section ended up open, so a caller can assert that its
    /// own check really inspected an open section. The chevron is the anchor, not
    /// the details container: when every activity in flight renders outside the
    /// section, an open section has no children and does not resolve.
    @discardableResult
    func expandActivityDetails(_ disclosure: XCUIElement? = nil, timeout: TimeInterval = 10) -> Bool {
        let control = disclosure ?? element("codex-activity-disclosure")
        guard control.exists else { return false }
        // A reopened conversation opens at the turn the user started, which can leave the
        // disclosure below the viewport; a click there would miss it.
        guard revealInConversation(control) else { return false }
        return waitUntil({
            let value = control.value as? String ?? ""
            if value.hasPrefix("Expanded") { return true }
            if value.hasPrefix("Collapsed") { control.click() }
            return (control.value as? String ?? "").hasPrefix("Expanded")
        }, timeout: timeout)
    }
    /// An agent row's metadata line, read from the row's button beside its icon.
    func subagentRowMetadata(_ row: XCUIElement) -> String {
        [row.value as? String, row.buttons.firstMatch.label].compactMap { $0 }.joined(separator: "\n")
    }
    func assertSubagentIconArtwork(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The row moves while the transcript appends beside it; a capture taken at a frame read
        // just before a move samples pixels beside the artwork. The sampled image is attached.
        XCTAssertTrue(waitForStableFrame(element), "The subagent icon should settle before its artwork is sampled.", file: file, line: line)
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Subagent icon artwork sample"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the subagent icon screenshot.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func colorAt(_ normalizedX: CGFloat, _ normalizedY: CGFloat) -> NSColor? {
            let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * normalizedX)))
            let y = min(cgImage.height - 1, max(0, Int(CGFloat(cgImage.height) * normalizedY)))
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }
        // The outline is only a few pixels wide, so sub-pixel placement can land the exact
        // sample on its anti-aliased edge; use the darkest slate pixel in a small neighborhood,
        // skipping the neutral row background around the icon.
        func darkestSlateColorNear(_ normalizedX: CGFloat, _ normalizedY: CGFloat, radius: Int = 2) -> NSColor? {
            let centerX = Int(CGFloat(cgImage.width) * normalizedX)
            let centerY = Int(CGFloat(cgImage.height) * normalizedY)
            let candidates = (-radius...radius).flatMap { dx in
                (-radius...radius).compactMap { dy -> NSColor? in
                    let x = min(cgImage.width - 1, max(0, centerX + dx))
                    let y = min(cgImage.height - 1, max(0, centerY + dy))
                    return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                }
            }
            return candidates.filter { $0.blueComponent > $0.redComponent * 1.15 }.min { max($0.redComponent, $0.greenComponent, $0.blueComponent) < max($1.redComponent, $1.greenComponent, $1.blueComponent) }
        }
        guard let topCyan = colorAt(0.5125, 0.2125),
              let leftEye = colorAt(0.3625, 0.4875),
              let face = colorAt(0.5125, 0.5125),
              let lowerLeftAccent = darkestSlateColorNear(0.2125, 0.7875) else {
            XCTFail("Could not sample the subagent icon artwork.", file: file, line: line)
            return
        }
        // The committed robot artwork: a white head and face, blue eyes, and a slate outline.
        for (part, color) in [("head", topCyan), ("face", face)] {
            XCTAssertGreaterThan(min(color.redComponent, color.greenComponent, color.blueComponent), 0.8, "The robot's \(part) should render white at its expected position.", file: file, line: line)
        }
        XCTAssertGreaterThan(leftEye.blueComponent, leftEye.redComponent * 1.4, "A blue eye should appear at the expected left-eye position.", file: file, line: line)
        XCTAssertGreaterThan(lowerLeftAccent.blueComponent, lowerLeftAccent.redComponent * 1.15, "The lower-left outline should retain the icon's slate color.", file: file, line: line)
        XCTAssertLessThan(max(lowerLeftAccent.redComponent, lowerLeftAccent.greenComponent, lowerLeftAccent.blueComponent), 0.6, "The lower-left outline should be dark.", file: file, line: line)
    }
    func assertContainsGreenForeground(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let greenPixels = pixelCount(in: element.screenshot().image) {
            $0.greenComponent > 0.35 && $0.redComponent < 0.65 && $0.blueComponent < 0.65
                && $0.greenComponent > $0.redComponent * 1.15 && $0.greenComponent > $0.blueComponent * 1.05
        }
        XCTAssertGreaterThan(greenPixels, 3, "The merged-PR completion checkmark should render green foreground pixels.", file: file, line: line)
    }
    func repositoryTitleHasColor(_ element: XCUIElement, appearance: String) -> Bool {
        guard let cgImage = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var matchingPixels = 0
        for x in 0..<cgImage.width {
            for y in 0..<cgImage.height {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let isMatch: Bool
                if appearance == "dark" {
                    isMatch = color.redComponent > 0.65
                        && color.greenComponent > 0.25
                        && color.redComponent > color.greenComponent * 1.3
                        && color.blueComponent < 0.25
                } else {
                    isMatch = color.blueComponent > color.redComponent * 1.5
                        && color.blueComponent > color.greenComponent * 1.2
                        && color.greenComponent > 0.18
                }
                if isMatch { matchingPixels += 1 }
            }
        }
        return matchingPixels > 3
    }
    func repositoryTitle() -> XCUIElement {
        element("empty-conversation-repository-title")
    }
    /// Playhouse's own prompts render as muted automatic messages: the history entry that holds `text`
    /// is shown under the `playhouse-message-` identifier with its label, never as the user's bubble.
    @discardableResult
    func assertAutomaticMessageBubble(taskID: String, containing text: String, sender: String = "Playhouse", file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any], file: file, line: line)
        let messages = try XCTUnwrap(history["messages"] as? [[String: Any]], file: file, line: line)
        let sent = try XCTUnwrap(
            messages.last { ($0["role"] as? String) == "user" && (($0["text"] as? String) ?? "").contains(text) },
            "History should hold the Playhouse-sent message containing: \(text)", file: file, line: line
        )
        let id = try XCTUnwrap(sent["id"] as? String, file: file, line: line)
        XCTAssertTrue(element("playhouse-message-\(id)").waitToExist(timeout: 10), "The message renders as an automatic Playhouse message.", file: file, line: line)
        let label = element("playhouse-message-label-\(id)")
        XCTAssertTrue(label.waitToExist(timeout: 5), "The automatic message carries its label.", file: file, line: line)
        XCTAssertTrue(label.label.contains("Automatic message from \(sender)") || ((label.value as? String) ?? "").contains("Automatic message from \(sender)"), "The label says the message is automatic from \(sender): \(label.label)", file: file, line: line)
        XCTAssertFalse(element("user-message-\(id)").exists, "An automatic message is not rendered as the user's own bubble.", file: file, line: line)
        return element("playhouse-message-\(id)")
    }
    /// The transcript's last row: the newest message, which can be the reply to a status nudge
    /// sent after the turn the test is watching.
    func latestMessageRow(titled title: String) throws -> XCUIElement {
        let id = try taskID(named: title)
        let history = try XCTUnwrap(try runCLI(["conversation", "history", id])["result"] as? [String: Any])
        return try transcriptRow(for: try XCTUnwrap((history["messages"] as? [[String: Any]])?.last))
    }
    /// The transcript element a history message renders as.
    func transcriptRow(for message: [String: Any]) throws -> XCUIElement {
        let isAutomatic = (message["role"] as? String) == "user"
            && ((message["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:")
        let prefix = isAutomatic ? "playhouse-message-" : ((message["role"] as? String) == "assistant" ? "assistant-message-" : "user-message-")
        return element(prefix + (try XCTUnwrap(message["id"] as? String)))
    }
    /// History without the status nudges Playhouse sent and the agent's replies to them.
    func ordinaryMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var kept: [[String: Any]] = []
        var inNudge = false
        for message in messages {
            if (message["role"] as? String) == "user" {
                inNudge = ((message["text"] as? String) ?? "").contains("Playhouse internal outcome nudge:")
            }
            if !inNudge { kept.append(message) }
        }
        return kept
    }
    /// Whether a transcript message shows this text, as a message group's label
    /// or as a text view's value.
    func transcriptContains(_ text: String) -> Bool {
        app.groups.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch.exists
            || app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists
            || app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }
    /// Refreshes a standalone chat through its visible navigation controls: the board sidebar's
    /// Chat entry hides it, then after a relaunch the same entry shows it again.
    func refreshStandaloneChatSidebar() {
        let chatEntry = element("chat-sidebar-button")
        XCTAssertTrue(waitUntil({ chatEntry.exists && chatEntry.isHittable }, timeout: 5), "The board sidebar's Chat entry should be a visible way to hide the chat.")
        chatEntry.click()
        XCTAssertTrue(waitUntil({ !self.element("chat-sidebar").exists }, timeout: 5), "Pressing the Chat entry should slide the chat sidebar away.")
        let parent = launchDefaultParent
        XCTAssertTrue(terminateAppAndWait(app), "Playhouse must stop before restoring the test window frame.")
        clearSavedWindowFrames()
        launchApp(defaultParent: parent)
        let chatButton = element("chat-sidebar-button")
        XCTAssertTrue(waitUntil({ chatButton.exists && chatButton.isHittable }, timeout: 5), "The board sidebar's Chat entry should be available again after the relaunch.")
        chatButton.click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10), "The standalone chat should reopen from the board.")
        waitForConversationLoad()
        // The chat slides out from the sidebar's edge; callers click its composer next.
        XCTAssertTrue(waitForStableFrame(element("message-composer")), "The reopened chat's composer settles.")
    }
    /// Waits for transcript text, scrolling down on each miss: the lazy transcript
    /// only exposes rows near the viewport.
    func transcriptShows(_ text: String, timeout: TimeInterval) -> Bool {
        waitUntil({
            if self.transcriptContains(text) { return true }
            self.element("conversation-scroll-view").scroll(byDeltaX: 0, deltaY: -300)
            return false
        }, timeout: timeout)
    }
    /// Runs `body` against the app's SQLite conversation store, which the app
    /// and its bridge daemon share in WAL mode.
    func withConversationDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let path = dataDirectory.appendingPathComponent("Conversations-v1.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "PlayhouseUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open the conversation store at \(path)."])
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 30_000)
        return try body(database)
    }
    /// Rows of a query against the conversation store, as text columns.
    func conversationRows(_ sql: String) throws -> [[String?]] {
        try withConversationDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "PlayhouseUITests", code: 5, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String?]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
            return rows
        }
    }
    func conversationExecute(_ sql: String) throws {
        try withConversationDatabase { database in
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "PlayhouseUITests", code: 6, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
        }
    }
    /// The task's stored conversation state, or nil before anything is recorded.
    func conversationState(_ taskID: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("Conversations-v1.sqlite").path) else { return nil }
        return try withConversationDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT payload FROM conversation_state WHERE task_id = ?", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "PlayhouseUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, taskID.uppercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any]
        }
    }
    func writeConversationState(_ taskID: String, _ state: [String: Any]) throws {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        try withConversationDatabase { database in
            var statement: OpaquePointer?
            let sql = "INSERT INTO conversation_state (task_id, payload) VALUES (?, ?) ON CONFLICT(task_id) DO UPDATE SET payload = excluded.payload"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "PlayhouseUITests", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, taskID.uppercased(), -1, transient)
            sqlite3_bind_text(statement, 2, payload, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "PlayhouseUITests", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
            }
        }
    }
    /// Replaces the task's stored turns with 60 settled question-and-answer turns in its newest
    /// provider segment, as earlier sessions would have recorded them. Playhouse keeps the
    /// transcript itself, so a long history is written into its store rather than read from a
    /// provider. Mirrors the CLI suite's `seed_long_history`; quit the app before calling it.
    /// With `switchAfterTurn`, the turns up to it belong to the previous segment and the rest to the
    /// newest, with a switch to the newest provider and back stored between them with nothing sent in
    /// between, as older conversations recorded an undone switch. `latestCommentary` gives the newest
    /// turn a commentary message before its answer. The CLI suite's `seed_long_history` writes the same rows.
    func seedLongHistory(
        _ taskID: String, sentPrompt: Bool = false, midHistoryCommand: Bool = false, tallLatestAnswer: Bool = false,
        switchAfterTurn: Int? = nil, latestCommentary: Bool = false
    ) throws {
        let key = taskID.uppercased()
        var state = try XCTUnwrap(try conversationState(key))
        var segments = try XCTUnwrap(state["segments"] as? [[String: Any]])
        let segment = try XCTUnwrap(segments.last)
        var earlierSegment = segment
        if switchAfterTurn != nil {
            earlierSegment = segments[segments.count - 2]
            let undone = [(segment, "segment_undone_switch"), (earlierSegment, "segment_undone_switch_back")].map { source, id in
                source.merging(["id": id, "codexTurnIDs": [String](), "codexTurnModelIDs": [String: String]()]) { _, new in new }
            }
            segments.insert(contentsOf: undone, at: segments.count - 1)
            state["segments"] = segments
            try writeConversationState(key, state)
        }
        var turns: [(id: String, messages: [(id: String, role: String, text: String)], activities: [[String: Any]])] = []
        if sentPrompt {
            // The sent prompt is the first stored user message, outside the newest history page.
            turns.append(("turn_sent_prompt", [("item_sent_prompt", "user", "Create a long history.")], []))
        }
        for index in 1...60 {
            let number = String(format: "%02d", index)
            var answer = "Long history assistant \(number)."
            if index == 60 && tallLatestAnswer {
                // A newest answer taller than the transcript viewport, so a conversation opened
                // on its question differs visibly from one opened at its end.
                answer = ([answer] + (1...30).map { String(format: "Long history closing paragraph %02d.", $0) }).joined(separator: "\n\n")
            }
            var activities: [[String: Any]] = []
            if index == 21 && midHistoryCommand {
                // A mid-history call whose output runs past the clipped lines, so the UI can
                // expand it and check it stays expanded after its row is rendered lazily again.
                activities.append([
                    "id": "item_long_history_command_21", "tool": "Bash", "title": "Running ls fixture-history",
                    "input": "ls fixture-history", "detail": "ls fixture-history", "summary": "in /tmp/playhouse-fixture", "status": "completed",
                    "durationMs": 5, "isContextCompaction": false, "afterMessageID": "item_long_history_user_21",
                    "output": (1...6).map { "history-file-\($0).txt\n" }.joined(),
                ])
            }
            var messages: [(id: String, role: String, text: String)] = [("item_long_history_user_\(index)", "user", "Long history user \(number).")]
            if index == 60 && latestCommentary {
                messages.append(("item_long_history_commentary_60", "commentary", "Long history commentary 60."))
            }
            messages.append(("item_long_history_assistant_\(index)", "assistant", answer))
            turns.append(("turn_long_history_\(index)", messages, activities))
        }
        try withConversationDatabase { database in
            func run(_ sql: String, _ values: [Any]) throws {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw NSError(domain: "PlayhouseUITests", code: 7, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (offset, value) in values.enumerated() {
                    if let number = value as? Int {
                        sqlite3_bind_int64(statement, Int32(offset + 1), Int64(number))
                    } else {
                        sqlite3_bind_text(statement, Int32(offset + 1), "\(value)", -1, transient)
                    }
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw NSError(domain: "PlayhouseUITests", code: 8, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
                }
            }
            func json(_ object: [String: Any]) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            for table in ["conversation_turns", "conversation_messages", "conversation_activities"] {
                try run("DELETE FROM \(table) WHERE task_id = ?", [key])
            }
            for (offset, turn) in turns.enumerated() {
                let turnSegment = switchAfterTurn.map { offset + 1 <= $0 } == true ? earlierSegment : segment
                let segmentID = try XCTUnwrap(turnSegment["id"] as? String)
                let provider = try XCTUnwrap(turnSegment["provider"] as? String)
                try run("INSERT INTO conversation_turns (task_id, id, segment_id, seq) VALUES (?, ?, ?, ?)", [key, turn.id, segmentID, offset + 1])
                for (position, message) in turn.messages.enumerated() {
                    var payload: [String: Any] = ["id": message.id, "role": message.role == "commentary" ? "assistant" : message.role,
                                                  "text": message.text, "turnID": turn.id, "imageDataURLs": [String](), "provider": provider]
                    if message.role != "user" { payload["phase"] = message.role == "commentary" ? "commentary" : "final_answer" }
                    try run("INSERT INTO conversation_messages (task_id, turn_id, id, position, payload) VALUES (?, ?, ?, ?, ?)",
                            [key, turn.id, message.id, position, try json(payload)])
                }
                for (position, activity) in turn.activities.enumerated() {
                    var payload = activity
                    payload["turnID"] = turn.id
                    try run("INSERT INTO conversation_activities (task_id, turn_id, id, position, payload) VALUES (?, ?, ?, ?, ?)",
                            [key, turn.id, try XCTUnwrap(activity["id"] as? String), position, try json(payload)])
                }
            }
        }
    }
    /// Scrolls `scrollView` until `element` sits fully inside it, or, for an element taller than
    /// the scroll view, until its top edge is at the scroll view's top. Custom accessibility
    /// elements, such as one paragraph of a reply's shared text, are not scrolled into view by a
    /// click.
    @discardableResult
    func scrollFullyIntoView(_ element: XCUIElement, in scrollView: XCUIElement, margin: CGFloat = 8) -> Bool {
        for _ in 0..<40 {
            let viewport = scrollView.frame
            let frame = element.frame
            let delta: CGFloat
            if frame.height > viewport.height {
                let offset = frame.minY - viewport.minY
                if abs(offset) <= 4 { return true }
                delta = -offset
            } else {
                // An element nearly as tall as the viewport fits only with a smaller margin.
                let margin = min(margin, (viewport.height - frame.height) / 2)
                // A wheel step shorter than a point moves nothing, so a shortfall that small
                // counts as in view rather than being scrolled at forever.
                if frame.minY < viewport.minY + margin - 1 {
                    delta = viewport.minY + margin - frame.minY
                } else if frame.maxY > viewport.maxY - margin + 1 {
                    delta = viewport.maxY - margin - frame.maxY
                } else {
                    return true
                }
            }
            scrollView.scroll(byDeltaX: 0, deltaY: max(-100, min(100, delta)))
        }
        return false
    }
    /// Opening a conversation renders only its newest turn, and older batches load as the
    /// reader scrolls up. Scrolls up as a reader would until every message is rendered, so
    /// an earlier turn can be asserted. The scroll view reports "Showing latest N of M".
    @discardableResult
    func revealWholeTranscript(step: CGFloat = 400, timeout: TimeInterval = 20) -> Bool {
        let scrollView = element("conversation-scroll-view")
        func renderedCounts() -> [Int] {
            (scrollView.value as? String ?? "").split(separator: " ").compactMap { Int($0) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let counts = renderedCounts()
            if counts.count == 2, counts[0] == counts[1] { return true }
            scrollView.scroll(byDeltaX: 0, deltaY: step)
            // A batch that needs its page read from the store is revealed a moment later.
            _ = waitUntil({ renderedCounts() != counts }, timeout: 1)
        }
        let counts = renderedCounts()
        return counts.count == 2 && counts[0] == counts[1]
    }
    /// Settled turns render lazily, so a row of an earlier turn exists only while it is near the
    /// viewport. Scrolls the transcript up, then back down, as a reader looking for it would,
    /// until `target` exists, then brings it into the viewport. A row found well outside the
    /// viewport may be one that renders only until it is measured and then becomes a box, so
    /// callers that go on to read it need it in view, where it stays rendered.
    @discardableResult
    func scrollTranscriptUntilExists(_ target: XCUIElement) -> Bool {
        let scrollView = element("conversation-scroll-view")
        func found() -> Bool {
            guard target.waitToExist(timeout: 1) else { return false }
            bringIntoTranscriptViewport(target, scrollView: scrollView)
            return target.exists
        }
        if found() { return true }
        for delta: CGFloat in [300, -300] {
            for _ in 0..<60 {
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
                if target.waitToExist(timeout: 0.3), found() { return true }
            }
        }
        return found()
    }
    /// Scrolls until `target`'s top lies inside the conversation's viewport, then waits for the
    /// transcript to settle the rows around it.
    func bringIntoTranscriptViewport(_ target: XCUIElement, scrollView: XCUIElement) {
        for _ in 0..<12 {
            // A streaming transcript can scroll the lazy row away between an existence
            // check and a frame read; a snapshot fails softly and the caller scrolls again.
            guard let top = (try? target.snapshot())?.frame.minY else { break }
            let viewport = scrollView.frame
            if top >= viewport.minY, top < viewport.maxY - 24 { break }
            // Wheel steps move less than their delta, so step by up to a viewport.
            let distance = top < viewport.minY ? viewport.minY + 24 - top : top - (viewport.maxY - 24) + 24
            scrollView.scroll(byDeltaX: 0, deltaY: (top < viewport.minY ? 1 : -1) * min(viewport.height, distance * 2))
            _ = waitForStableFrame(target, timeout: 1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    /// The transcript scroller's position, 0 at the top and 1 at the bottom; nil while the
    /// transcript does not overflow.
    func transcriptScrollPosition() -> Double? {
        let scroller = element("conversation-scroll-view").scrollBars.firstMatch
        guard scroller.exists else { return nil }
        if let number = scroller.value as? NSNumber { return number.doubleValue }
        return (scroller.value as? String).flatMap(Double.init)
    }
    /// Reveals every message and scrolls the transcript to its very top. Reports whether it got
    /// there; a transcript that does not overflow is already at its top.
    @discardableResult
    func scrollTranscriptToTop() -> Bool {
        let scrollView = element("conversation-scroll-view")
        // Reaching the top of the rendered messages reveals the batch above them, so the top of
        // the transcript is the top once every message is rendered.
        let revealed = revealWholeTranscript(step: 3000)
        for _ in 0..<40 {
            guard (transcriptScrollPosition() ?? 0) > 0.001 else { break }
            scrollView.scroll(byDeltaX: 0, deltaY: 3000)
        }
        return revealed && (transcriptScrollPosition() ?? 0) <= 0.001
    }
    /// Settled turns render lazily, so a check over the whole revealed transcript has to look at
    /// it a viewport at a time. Scrolls the conversation to its top, then down to its bottom in
    /// steps shorter than the viewport, checking `found` at every step, and reports whether it
    /// held at any step and whether the scan covered the whole transcript. The scroller's value
    /// reports the position, 0 at the top and 1 at the bottom.
    func scanTranscript(_ found: () -> Bool) -> (found: Bool, coveredWholeTranscript: Bool) {
        if found() { return (true, true) }
        let scrollView = element("conversation-scroll-view")
        func position() -> Double? { transcriptScrollPosition() }
        guard position() != nil else { return (found(), false) }
        let reachedTop = scrollTranscriptToTop()
        let step = -max(100, scrollView.frame.height * 0.6)
        for _ in 0..<400 {
            // Rows near the viewport are realized a moment after a scroll lands.
            if waitUntil(found, timeout: 0.5) { return (true, true) }
            guard let current = position() else { return (false, false) }
            if current >= 0.999 { return (found(), reachedTop) }
            scrollView.scroll(byDeltaX: 0, deltaY: step)
            // A step that does not move the scroller would end the scan short of the bottom.
            guard let moved = position(), moved > current else { return (found(), false) }
        }
        return (found(), false)
    }
    /// Whether `found` holds anywhere in the transcript, scanning it a viewport at a time.
    func transcriptScan(_ found: () -> Bool) -> Bool {
        scanTranscript(found).found
    }
    /// Asserts that `found` holds nowhere in the transcript. The scan must have covered it
    /// from its top to its bottom, so a scan cut short cannot pass as an absence.
    func assertTranscriptLacks(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ found: () -> Bool) {
        let scan = scanTranscript(found)
        XCTAssertTrue(scan.coveredWholeTranscript, "The transcript scan must reach both its top and its bottom: \(message)", file: file, line: line)
        XCTAssertFalse(scan.found, message, file: file, line: line)
    }
    /// A user message in the transcript, which is exposed as a labeled group.
    func transcriptMessage(_ text: String) -> XCUIElement {
        app.groups[text].firstMatch
    }
}

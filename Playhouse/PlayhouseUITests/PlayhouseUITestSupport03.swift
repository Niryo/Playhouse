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
    func effortTitle(of slider: XCUIElement) -> String? {
        if let title = slider.value as? String { return title }
        guard let index = (slider.value as? NSNumber)?.intValue else { return nil }
        let titles = ["Low", "Medium", "High", "Extra High"]
        return titles.indices.contains(index) ? titles[index] : nil
    }
    func modelPrompt() -> XCUIElement {
        element("model-prompt")
    }
    func deleteTaskFromContextMenu(_ title: String) {
        let card = app.buttons[title].firstMatch
        XCTAssertTrue(card.waitToExist(timeout: 5))
        card.rightClick()
        let deleteAction = element("delete-task-menu-item")
        XCTAssertTrue(deleteAction.waitToExist(timeout: 5), "The task context menu should offer Delete Task.")
        deleteAction.click()
    }
    func assertOrderedRoots(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        let titleElement = element("task-view-title")
        let taskTitle = (titleElement.value as? String) ?? titleElement.label
        let task = try? taskRecord(named: taskTitle)
        let repositories = (task?["repositoryWorktrees"] as? [[String: Any]] ?? [])
            .compactMap { $0["worktreePath"] as? String }
        let contextFolders = paths.filter { !repositories.contains($0) }
        let summary = element("working-folders-summary")
        guard !contextFolders.isEmpty else {
            XCTAssertFalse(summary.exists, "Repository worktrees should not be repeated as additional working folders.", file: file, line: line)
            return
        }
        XCTAssertTrue(summary.waitToExist(timeout: 10), "Working folder summary is missing.", file: file, line: line)
        let text = [summary.label, summary.value as? String ?? "", summary.placeholderValue ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for repositoryPath in repositories {
            let repositoryName = URL(fileURLWithPath: repositoryPath).lastPathComponent
            XCTAssertFalse(text.contains(repositoryPath), "Repository worktrees should not appear in the additional-folder summary.", file: file, line: line)
            XCTAssertFalse(text.contains(repositoryName), "Repository labels should not be duplicated in the additional-folder summary.", file: file, line: line)
        }
        var searchStart = text.startIndex
        for path in contextFolders {
            XCTAssertEqual(
                text.components(separatedBy: path).count - 1,
                1,
                "Folder selection should contain each root once. Expected path: \(path). Accessibility text: \(text)",
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
    func chooseFolder(in panel: XCUIElement, folder: URL, confirmationButton: String) throws {
        XCTAssertTrue(panel.waitToExist(timeout: 10), "The system folder panel did not open.")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitToExist(timeout: 5), "Go to Folder did not open from the system panel.")
        let pathField = goToSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitToExist(timeout: 5))
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
        XCTAssertTrue(chooseButton.waitToExist(timeout: 10), "Folder panel did not show \(confirmationButton).")
        chooseButton.click()
    }
    func assertText(
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
    func tasksFromBoardList() throws -> [[String: Any]] {
        let response = try runCLI(["board", "list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["tasks"] as? [[String: Any]])
    }
    func agentManifests() -> [(kind: String, path: URL, manifest: [String: Any])] {
        var manifests: [(String, URL, [String: Any])] = []
        let codexRuns = dataDirectory.appendingPathComponent("codex-runs", isDirectory: true)
        for url in ((try? FileManager.default.contentsOfDirectory(at: codexRuns, includingPropertiesForKeys: nil)) ?? [])
        where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            if let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] {
                manifests.append(("codex", url, object))
            }
        }
        let claudeRuns = dataDirectory.appendingPathComponent("provider-runs", isDirectory: true)
        for folder in ((try? FileManager.default.contentsOfDirectory(at: claudeRuns, includingPropertiesForKeys: nil)) ?? []) {
            let url = folder.appendingPathComponent("run.json")
            if let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] {
                manifests.append(("claude", url, object))
            }
        }
        return manifests
    }
    func agentIsAlive(_ process: [String: Any]?) -> Bool {
        guard let pid = (process?["pid"] as? NSNumber)?.int32Value,
              let startTime = (process?["startTime"] as? NSNumber)?.int64Value else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return false }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec) == startTime
    }
    func stopSurvivingAgents() {
        for entry in agentManifests() where agentIsAlive(entry.manifest["process"] as? [String: Any]) {
            if let pid = ((entry.manifest["process"] as? [String: Any])?["pid"] as? NSNumber)?.int32Value {
                killpg(pid, SIGKILL)
            }
        }
    }
    func restartServiceEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).restart-\(UUID().uuidString.prefix(8))"].merging(extra) { _, new in new }
    }
    func agentManifest(kind: String, service: [String: String]) -> (path: URL, manifest: [String: Any])? {
        agentManifests().first { $0.kind == kind && $0.manifest["serviceName"] as? String == service["PLAYHOUSE_BRIDGE_SERVICE_NAME"] }
            .map { ($0.path, $0.manifest) }
    }
    func killDaemon(environment: [String: String]) throws {
        let pid = try XCTUnwrap(try daemonProcessID(environment: environment), "The private daemon should be running.")
        kill(pid_t(pid), SIGKILL)
        XCTAssertTrue(waitUntil({ kill(pid_t(pid), 0) != 0 }, timeout: 10), "The killed daemon should exit.")
    }
    func launchRestartFixtureChat(provider: String = "claude") throws -> (executable: String, environment: [String: String], chatID: String) {
        let executable = WorkspaceFixture.root.appendingPathComponent("\(provider)-fixture-reattach").path
        if provider == "codex" { codexFixtureExecutable = executable } else { claudeFixtureExecutable = executable }
        clearReattachMarkers(executable)
        let environment = restartServiceEnvironment()
        // Set up through the runner's service, as the other restart cases do: the private
        // service's daemon starts with the window that uses it.
        _ = try runCLI(["settings", "set-default-provider", provider])
        _ = try runCLI(["settings", "clear-parent"])
        let chatID = try XCTUnwrap((try runCLI(["chat", "open"])["result"] as? [String: Any])?["id"] as? String)
        launchApp(defaultParent: nil, environmentOverrides: environment)
        element("chat-sidebar-button").click()
        XCTAssertTrue(element("chat-sidebar").waitToExist(timeout: 10))
        return (executable, environment, chatID)
    }
    func restartChatStatus(_ environment: [String: String]) -> [String: Any]? {
        (try? runCLI(["chat", "status"], extraEnvironment: environment))?["result"] as? [String: Any]
    }
    func restartChatPageTexts(_ pageID: String, environment: [String: String]) -> [String] {
        let page = (try? runCLI(["chat", "page", "read", pageID], extraEnvironment: environment))?["result"] as? [String: Any]
        return (page?["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }
    func startRestartChatTurn(_ executable: String, _ text: String) {
        try? FileManager.default.removeItem(atPath: executable + ".reattach-ready")
        sendFromComposer(text)
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".reattach-ready") }, timeout: 20),
                      "The chat turn \(text) runs.")
    }
    func closeHeldChatTurn(_ executable: String, newTitle: String? = nil) {
        let output = executable + ".reattach-close-turn-output"
        let before = jsonLines(output).count
        FileManager.default.createFile(atPath: executable + ".reattach-close-turn", contents: Data((newTitle ?? "").utf8))
        XCTAssertTrue(waitUntil({ self.jsonLines(output).count > before }, timeout: 20), "The held chat turn runs close-turn.")
        let result = jsonLines(output).last as? [String: Any]
        XCTAssertEqual(result?["returncode"] as? Int, 0, "close-turn succeeds: \(String(describing: result))")
    }
    func sendFiledRestartChatTurn(
        _ executable: String, _ text: String, newTitle: String? = nil, environment: [String: String]
    ) -> String {
        startRestartChatTurn(executable, text)
        let ready = (try? String(contentsOfFile: executable + ".reattach-ready", encoding: .utf8)) ?? ""
        // Claude's ready file holds the prompt itself, Codex's a JSON record with it.
        let received = ((try? JSONSerialization.jsonObject(with: Data(ready.utf8))) as? [String: Any])?["text"] as? String ?? ready
        closeHeldChatTurn(executable, newTitle: newTitle)
        touch(executable + ".reattach-release-quiet")
        XCTAssertTrue(waitUntil({
            let runtime = (try? self.runCLI(["conversation", "runtime"], extraEnvironment: environment))?["result"] as? [String: Any]
            return runtime != nil && (runtime?["activeThreadIDs"] as? [String] ?? []).isEmpty
                && self.agentManifest(kind: "claude", service: environment) == nil
        }, timeout: 30), "The chat turn finishes.")
        return received
    }
    func unfileChatPageForLegacyState(_ pageID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dataDirectory.appendingPathComponent("StandaloneChat-v1.sqlite").path,
            "DELETE FROM chat_messages WHERE page_id = '\(pageID)'; UPDATE chat_pages SET message_count = 0 WHERE id = '\(pageID)'; DELETE FROM chat_turn_signals WHERE page_id = '\(pageID)';",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The legacy page state is seeded.")
    }
    func clearReattachMarkers(_ executable: String) {
        let folder = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let name = URL(fileURLWithPath: executable).lastPathComponent
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasPrefix(name + ".") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
    func jsonLines(_ path: String) -> [Any] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed])
        }
    }
    func historyTexts(taskID: String, environment: [String: String] = [:]) throws -> [String] {
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        return (history["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }
    func sendFromComposer(_ text: String) {
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15))
        composer.click()
        composer.typeText(text)
        // A task waiting on a response offers Continue as its send action.
        let send = element("send-message-button")
        if send.waitToExist(timeout: 3) { send.click() } else { element("continue-response-button").click() }
    }
    func steerFromComposer(_ text: String) {
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15))
        composer.click()
        composer.typeText(text)
        composer.typeKey(.return, modifierFlags: .command)
    }
    func touch(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    func waitForStatus(_ taskID: String, _ status: String, environment: [String: String] = [:], timeout: TimeInterval = 30) -> Bool {
        waitUntil({
            let record = (try? self.runCLI(["task", "get", taskID], extraEnvironment: environment))?["result"] as? [String: Any]
            return record?["status"] as? String == status
        }, timeout: timeout)
    }
    func taskRecord(named title: String) throws -> [String: Any]? {
        try tasksFromBoardList().first { $0["title"] as? String == title }
    }
    func daemonLogProcessIDs(service: String) -> Set<Int> {
        let digest = SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined()
        let log = "/tmp/playhouse-bridge/\(getuid())/\(digest.prefix(32)).sock.log"
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let pattern = try! NSRegularExpression(pattern: #"playhouse-daemon\[(\d+)\]"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
        })
    }
    func daemonProcessID(environment: [String: String]) throws -> Int? {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["status"]
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        // This read can be the first request a fresh daemon serves, and that request's provider
        // clients follow any reattached turn, so it carries the case's fixtures like `runCLI`.
        processEnvironment.merge(providerExecutableEnvironment) { _, new in new }
        processEnvironment.merge(environment) { _, override in override }
        process.environment = processEnvironment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let line = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last,
              let response = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return (response["result"] as? [String: Any])?["processID"] as? Int
    }
    func taskRecord(id: String) throws -> [String: Any]? {
        let response = try runCLI(["task", "get", id])
        return response["result"] as? [String: Any]
    }
    func repositoryRecord(taskID: String, repositoryPath: String) throws -> [String: Any]? {
        guard let task = try taskRecord(id: taskID),
              let repositories = task["repositoryWorktrees"] as? [[String: Any]] else { return nil }
        return repositories.first { ($0["repositoryPath"] as? String) == repositoryPath }
    }
    func waitForRepositoryValue(
        taskID: String,
        repositoryPath: String,
        key: String,
        expected: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        waitUntil({
            do {
                guard let record = try self.repositoryRecord(taskID: taskID, repositoryPath: repositoryPath) else { return false }
                return record[key] as? String == expected
            } catch {
                return false
            }
        }, timeout: timeout)
    }
    func fixtureTurnCount(_ executable: URL, containing text: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: executable.path + ".history")),
              let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turns = history["turns"] as? [[String: Any]] else { return 0 }
        return turns.filter {
            let prompt = ($0["userText"] ?? $0["userMessage"]) as? String ?? ""
            return prompt.contains(text) && !prompt.hasPrefix("Classify the latest user message")
        }.count
    }
    func noTurnIsRunning() -> Bool {
        guard let runtime = try? runCLI(["conversation", "runtime"])["result"] as? [String: Any] else { return false }
        return (runtime["activeThreadIDs"] as? [String] ?? []).isEmpty && !element("pause-response-button").exists
    }
    func providerFixtureViolations() -> [String] {
        guard let events = try? diagnosticEvents() else {
            // A case that launched the app always has a diagnostics log to check.
            return app == nil ? [] : ["The case's Diagnostics.jsonl could not be read, so provider launches were not verified."]
        }
        let fixtureRoots = [WorkspaceFixture.root.path, runDirectory.path]
        return events.compactMap { event in
            guard let name = event["event"] as? String,
                  ["codex.app_server.started", "claude.process.started", "github.cli.started"].contains(name) else { return nil }
            let executable = event["executable"] as? String ?? ""
            guard !fixtureRoots.contains(where: { executable.hasPrefix($0 + "/") }) else { return nil }
            if name == "github.cli.started" {
                let operation = event["operation"] as? String ?? ""
                return "gh \(operation) ran \(executable) instead of the gh fixture; give the case the gh fixture, or set a task that is not about pull requests to Manual mode."
            }
            return "\(name) launched \(executable) instead of a test fixture; give the app the case's fixture before it reads the conversation."
        }
    }
    func diagnosticEvents() throws -> [[String: Any]] {
        let log = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        return try log.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
    func taskID(named title: String) throws -> String {
        let record = try XCTUnwrap(taskRecord(named: title), "No task named \(title) exists in the real store.")
        return try XCTUnwrap(record["id"] as? String)
    }
    func seedLegacyStandaloneChatTask(sessionID: String = "legacy-chat-session") throws -> String {
        let seeder = WorkspaceFixture.root.appendingPathComponent("seed-legacy-standalone-chat-task")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: seeder.path), "The precompiled legacy chat seeder should be executable.")

        let seed = Process()
        seed.executableURL = seeder
        seed.arguments = [dataDirectory.path, sessionID]
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seedText = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, "The legacy hidden chat task should be seeded: \(seedText)")
        return try XCTUnwrap(seedText.split(whereSeparator: \.isNewline).last.map(String.init))
    }
    func settledPillOption(_ mode: String, taskID: String) -> XCUIElement {
        let option = element("task-pr-mode-\(mode)-\(taskID)")
        XCTAssertTrue(option.waitToExist(timeout: 5), "The open pill should offer \(mode).")
        var lastFrame = CGRect.null
        XCTAssertTrue(waitUntil({
            let frame = option.frame
            defer { lastFrame = frame }
            return option.isHittable && frame == lastFrame
        }, timeout: 5), "The pill's \(mode) option should finish sliding in.")
        return option
    }
    func selectPullRequestMode(_ mode: String, taskID: String) throws {
        let pill = element("task-pr-mode-\(taskID)")
        XCTAssertTrue(pill.waitToExist(timeout: 5), "The task card should show its PR mode pill.")
        pill.click()
        let option = settledPillOption(mode, taskID: taskID)
        option.click()
        XCTAssertTrue(waitUntil({ pill.exists && (pill.value as? String) == mode }, timeout: 5), "The pill should fold back onto \(mode).")
    }
    func seedTaskPullRequest(taskID: String, number: Int, url: String, repositoryIndex: Int = 0) throws {
        let seeder = WorkspaceFixture.root.appendingPathComponent("seed-task-pr-link")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: seeder.path), "The precompiled SwiftData fixture seeder should be executable.")

        let seed = Process()
        seed.executableURL = seeder
        seed.arguments = [dataDirectory.path, taskID, String(number), url]
        if repositoryIndex > 0 { seed.arguments?.append(String(repositoryIndex)) }
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seedText = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, "The isolated SwiftData task record should be seeded: \(seedText)")
        XCTAssertTrue(seedText.contains("Seeded linked PR #\(number)"), seedText)
    }
    func seedLegacyPluginTask(taskID: String, pluginID: String) throws {
        let process = Process()
        process.executableURL = WorkspaceFixture.root.appendingPathComponent("seed-task-pr-link")
        process.arguments = [dataDirectory.path, taskID, "--legacy-plugin", pluginID, pluginsFolder.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
    }
    func clearTaskProviderSession(taskID: String) throws {
        let seeder = WorkspaceFixture.root.appendingPathComponent("seed-task-pr-link")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: seeder.path), "The precompiled SwiftData fixture seeder should be executable.")

        let seed = Process()
        seed.executableURL = seeder
        seed.arguments = [dataDirectory.path, taskID, "--clear-provider-session"]
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seedText = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, "The isolated SwiftData task session should be cleared: \(seedText)")
        XCTAssertTrue(seedText.contains("Cleared provider sessions"), seedText)
    }
    func runCLI(
        _ arguments: [String],
        expectedStatus: Int32 = 0,
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        environment["CODEX_HOME"] = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment.merge(providerExecutableEnvironment, uniquingKeysWith: { _, new in new })
        if let codexFixtureStateDirectory {
            environment["PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY"] = codexFixtureStateDirectory.path
        }
        environment.merge(extraEnvironment) { _, override in override }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain both pipes while the CLI runs: a reply larger than the pipe
        // buffer (a long history with images) would otherwise block its write
        // while this waits for it to exit.
        var errorData = Data()
        let errorDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            errorDrained.signal()
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        errorDrained.wait()
        process.waitUntilExit()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, expectedStatus, "CLI \(arguments) exited unexpectedly: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last, "CLI returned no JSON for \(arguments)")
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any],
            "CLI response was not a JSON object."
        )
        XCTAssertEqual(response["version"] as? Int, 1)
        // `task create` requires a prompt, but most UI cases open the task's conversation and
        // need an empty composer. Fixture creations carry a placeholder prompt that is cleared
        // right away; cases that exercise the saved prompt pass their own text instead.
        if expectedStatus == 0, arguments.starts(with: ["task", "create"]), arguments.contains(Self.fixtureTaskPrompt),
           let createdID = (response["result"] as? [String: Any])?["id"] as? String {
            _ = try runCLI(["task", "prompt", createdID, "--text", ""], extraEnvironment: extraEnvironment)
        }
        return response
    }
    func startCLIProcess(
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) throws -> RunningCLIProcess {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment.merge(providerExecutableEnvironment, uniquingKeysWith: { _, new in new })
        environment.merge(extraEnvironment) { _, override in override }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return RunningCLIProcess(process: process, stdout: stdout, stderr: stderr)
    }
    func finishCLIProcess(_ running: RunningCLIProcess, expectedStatus: Int32? = 0) throws -> [String: Any] {
        try finishCLIProcessCapturingEvents(running, expectedStatus: expectedStatus).response
    }
    func finishCLIProcessCapturingEvents(
        _ running: RunningCLIProcess,
        expectedStatus: Int32? = 0
    ) throws -> (response: [String: Any], events: [[String: Any]]) {
        running.process.waitUntilExit()
        let output = String(data: running.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: running.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let expectedStatus {
            XCTAssertEqual(running.process.terminationStatus, expectedStatus, "CLI exited unexpectedly: \(output) \(errorOutput)")
        }
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last, "CLI returned no JSON response: \(errorOutput)")
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any],
            "CLI response was not a JSON object."
        )
        XCTAssertEqual(response["version"] as? Int, 1)
        let events = output.split(whereSeparator: \.isNewline).dropLast().compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        return (response, events)
    }
    func startProgressFixtureTurn(
        taskID: String,
        executable: URL
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe, activeMarker: URL, releaseMarker: URL) {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["conversation", "send", taskID, "--message", "Work on this task."]
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
        environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] = executable.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        try process.run()
        return (
            process, stdout, stderr,
            activeMarker,
            releaseMarker
        )
    }
    func runGit(_ repository: URL, _ arguments: String...) throws {
        _ = try runGitOutput(repository, arguments)
    }
    func runGitOutput(_ repository: URL, _ arguments: String...) throws -> String {
        try runGitOutput(repository, arguments)
    }
    func runGitOutput(_ repository: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let directGitPaths = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
        ]
        let gitPath = try XCTUnwrap(
            directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) },
            "UI tests need a direct Git executable; /usr/bin/git uses xcrun and cannot run in the test sandbox."
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repository.path] + arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "Git failed: \(errorOutput)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func assertCLIError(
        _ response: [String: Any],
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, code, file: file, line: line)
    }
    func chatPageSeparators(_ title: String) -> [XCUIElement] {
        element("chat-sidebar")
            .descendants(matching: .scrollView)
            .matching(identifier: "conversation-scroll-view")
            .firstMatch
            .staticTexts
            .matching(identifier: "chat-page-separator")
            .allElementsBoundByIndex
            .filter { $0.label == title || $0.value as? String == title }
            .sorted { $0.frame.minY < $1.frame.minY }
    }
    func chatTranscriptShows(_ text: String, belowPage title: String) -> Bool {
        guard let separator = chatPageSeparators(title).last else { return false }
        return element("chat-sidebar")
            .descendants(matching: .scrollView)
            .matching(identifier: "conversation-scroll-view")
            .firstMatch
            .groups.matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", text, text))
            .allElementsBoundByIndex
            .contains { $0.frame.minY > separator.frame.minY }
    }
    func chatPageSeparatorIsVisible(_ title: String) -> Bool {
        element("chat-sidebar")
            .descendants(matching: .scrollView)
            .matching(identifier: "conversation-scroll-view")
            .firstMatch
            .staticTexts
            // One query rather than reading each separator in turn: settled rows render only
            // near the viewport, so a separator can leave between listing it and reading it.
            // A static text reports its string as its value.
            .matching(NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "chat-page-separator", title, title))
            .firstMatch
            .exists
    }
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @discardableResult
    func waitForSideChatBubble(
        at selection: XCUIElement? = nil, centered: Bool = false, hintScreenshot: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> XCUIElement {
        // An assistant reply's hint takes its prose block's identifier, so it is found by label.
        let hint = app.buttons.matching(NSPredicate(format: "label == %@", "Side chat")).firstMatch
        let bubble = element("side-chat-bubble")
        XCTAssertTrue(hint.waitToExist(timeout: 8), "Selecting transcript text should show the Side chat hint.", file: file, line: line)
        XCTAssertEqual(hint.label, "Side chat", file: file, line: line)
        if let selection {
            // Measured against the selected text: a message's own frame also holds its header and padding.
            let textView = selection.textViews.firstMatch
            let hasTextView = textView.exists
            let selection = hasTextView ? textView : selection
            let hintFrame = hint.frame
            if hasTextView {
                // A user message's hint has room in its message, so its whole frame is above the text.
                XCTAssertLessThanOrEqual(hintFrame.maxY, selection.frame.minY + 8,
                                         "The Side chat hint should sit above the selected text (hint \(hintFrame), selection \(selection.frame)).", file: file, line: line)
            } else {
                // A reply's hint draws above its text too, but its accessibility frame is clipped to
                // that text's container, so only its top edge is reliable: never below the selection's.
                XCTAssertLessThanOrEqual(hintFrame.minY, selection.frame.minY + 4,
                                         "The Side chat hint should start above the selected text (hint \(hintFrame), selection \(selection.frame)).", file: file, line: line)
            }
            XCTAssertTrue(hintFrame.maxX > selection.frame.minX - 60 && hintFrame.minX < selection.frame.maxX + 60,
                          "The Side chat hint should be over the selected text's columns (hint \(hintFrame), selection \(selection.frame)).", file: file, line: line)
            // A whole-text selection's hint is centred on it, its bottom just above the selected lines.
            if centered {
                XCTAssertLessThan(abs(hintFrame.midX - selection.frame.midX), 70,
                                  "The Side chat hint should be centred over the selection (hint \(hintFrame), selection \(selection.frame)).", file: file, line: line)
                XCTAssertGreaterThanOrEqual(hintFrame.minY, selection.frame.minY - 60,
                                            "The Side chat hint should sit just above the selection (hint \(hintFrame), selection \(selection.frame)).", file: file, line: line)
            }
        }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(bubble.exists, "A selection alone must not open the side chat bubble.", file: file, line: line)
        if let hintScreenshot { attachScreenshot(named: hintScreenshot) }
        hint.click()
        XCTAssertTrue(bubble.waitToExist(timeout: 8), "Clicking the Side chat hint should open the side chat bubble.", file: file, line: line)
        XCTAssertTrue(waitUntil({ !hint.exists }, timeout: 3), "The Side chat hint should go away once its bubble is open.", file: file, line: line)
        XCTAssertTrue(waitForStableFrame(bubble), "The side chat bubble should settle before it is measured.", file: file, line: line)
        let frame = bubble.frame
        // Its accessibility frame is its content, inside the bubble's 14pt padding: 414 to 544 points wide.
        XCTAssertTrue((400...560).contains(frame.width), "The side chat bubble should be 442 to 572 points wide with its padding (\(frame)).", file: file, line: line)
        XCTAssertTrue((100...600).contains(frame.height), "The side chat bubble should fit its chat, up to its maximum height (\(frame)).", file: file, line: line)
        if let selection {
            let selected = selection.frame
            XCTAssertTrue(frame.maxX > selected.minX && frame.minX < selected.maxX,
                          "The bubble should open over the selected text's columns (bubble \(frame), selection \(selected)).",
                          file: file, line: line)
            // The bubble's edge meets the selected lines: below their last line, above their first,
            // or, for a selection inside the first line, right under it.
            let gap = min(abs(frame.minY - selected.maxY), abs(frame.maxY - selected.minY), abs(frame.minY - selected.minY))
            XCTAssertLessThan(gap, 60,
                              "The bubble should open right at the selection (bubble \(frame), selection \(selected)).",
                              file: file, line: line)
        }
        return bubble
    }
    func element(withAccessibilityLabel label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }
    func screenshotContains(srgb expected: (Int, Int, Int), in element: XCUIElement, tolerance: Int = 10) -> Bool {
        let image = element.screenshot().image
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let target = NSColor(
                  srgbRed: CGFloat(expected.0) / 255, green: CGFloat(expected.1) / 255,
                  blue: CGFloat(expected.2) / 255, alpha: 1
              ).usingColorSpace(bitmap.colorSpace) else { return false }
        let expected = (Int(round(target.redComponent * 255)), Int(round(target.greenComponent * 255)), Int(round(target.blueComponent * 255)))
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 120)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let rgb = (Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
                if abs(rgb.0 - expected.0) <= tolerance, abs(rgb.1 - expected.1) <= tolerance, abs(rgb.2 - expected.2) <= tolerance {
                    return true
                }
            }
        }
        return false
    }
    func terminalNumber(after marker: String, in terminal: XCUIElement) -> String? {
        guard let text = (terminal.value as? String)?.replacingOccurrences(of: "\n", with: ""),
              let range = text.range(of: marker, options: .backwards) else { return nil }
        let digits = text[range.upperBound...].prefix(while: \.isNumber)
        guard !digits.isEmpty, text[digits.endIndex...].first == ";" else { return nil }
        return String(digits)
    }
    func monacoEditorStatus(timeout: TimeInterval = 10) -> String {
        var status = ""
        _ = waitUntil({
            status = self.element("workspace-diff-editor-status").value as? String ?? ""
            return status.hasPrefix("Editor ")
        }, timeout: timeout)
        return status
    }
    func renderedDiffValue(timeout: TimeInterval = 10) -> String {
        var value = ""
        _ = waitUntil({
            value = self.element("workspace-diff-editor").value as? String ?? ""
            return value.contains("Original:")
        }, timeout: timeout)
        return value
    }
    func assertNativeHelpText(for element: XCUIElement, equals expected: String) {
        for attempt in 0..<3 {
            // Tooltips only show for the active app's key window.
            app.activate()
            movePointerToHelpRunway(below: element)
            Thread.sleep(forTimeInterval: 1.5)
            // Enter the control, then keep moving inside it: AppKit starts its tooltip delay from
            // a mouse-move within the tracking area, and a single jump in does not always count.
            element.hover()
            for dx in [0.35, 0.65, 0.45, 0.55] {
                Thread.sleep(forTimeInterval: 0.15)
                element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5 + CGFloat(attempt) * 0.05)).hover()
            }
            if waitUntil({ self.nativeHelpTextIsVisible(expected) }, timeout: 6) { return }
        }
        XCTFail("Hovering should present the native help text ‘\(expected)’ outside the PR control.")
    }
    func nativeHelpTextIsVisible(_ expected: String) -> Bool {
        helpTagIsShowing(expected) || screenTextContains(expected)
    }
    func screenTextContains(_ expected: String) -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // A tooltip wraps across lines, so compare word sequences without line breaks or punctuation.
        func words(_ text: String) -> String {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let onScreen = words((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
        return onScreen.contains(words(expected))
    }
    func helpTagIsShowing(_ text: String) -> Bool {
        app.descendants(matching: .helpTag)
            .matching(Self.textPredicate(containing: text, caseInsensitive: false, includeTitle: true))
            .firstMatch.exists
    }
    func assertNoNativeHelpText(whileHovering element: XCUIElement, containing text: String) {
        app.activate()
        movePointerToHelpRunway(below: element)
        Thread.sleep(forTimeInterval: 1.5)
        element.hover()
        // Keep moving inside the card the way `assertNativeHelpText` does, so a tooltip would get
        // its delay. The runner may not post CGEvents in the VM (WindowServer logs "Sender is
        // prohibited from synthesizing events"), so every move goes through XCUITest.
        for dx in [0.45, 0.55, 0.5, 0.52] {
            Thread.sleep(forTimeInterval: 0.15)
            element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).hover()
        }
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(nativeHelpTextIsVisible(text), "Hovering the card should not present a ‘\(text)’ tooltip.")
    }
    func dismissNativeHelpText(named expected: String) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
        movePointerToHelpRunway(below: element)
        // A single synthesized move can leave the system tooltip up until the next mouse
        // movement, so keep moving away before concluding that it did not dismiss.
        if !waitUntil({ !self.nativeHelpTextIsVisible(expected) }, timeout: 4) {
            movePointerToHelpRunway(below: element, horizontalShift: -60)
        }
        // A control at the window's right edge (the Done archive) can keep the tag up through
        // short moves beside it; a move well clear of every control ends it.
        if !waitUntil({ !self.nativeHelpTextIsVisible(expected) }, timeout: 4) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.85)).hover()
        }
        XCTAssertTrue(waitUntil({ !self.nativeHelpTextIsVisible(expected) }, timeout: 8), "Moving away should dismiss the native help text ‘\(expected)’ outside the PR control.")
    }
    func movePointerToHelpRunway(below control: XCUIElement, horizontalShift: CGFloat = 0) {
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        let controlFrame = control.frame
        let target = CGPoint(x: controlFrame.midX + horizontalShift, y: min(windowFrame.maxY - 10, controlFrame.maxY + 100))
        let offset = CGVector(
            dx: (target.x - windowFrame.minX) / windowFrame.width,
            dy: (target.y - windowFrame.minY) / windowFrame.height
        )
        window.coordinate(withNormalizedOffset: offset).hover()
    }
    static func isOrangePixel(_ color: NSColor) -> Bool {
        color.redComponent > 0.45 && color.redComponent > color.greenComponent + 0.08 && color.greenComponent > color.blueComponent + 0.08
    }
    func pixelCount(in image: NSImage, step: Int = 1, maxXFraction: CGFloat = 1.0, where matches: (NSColor) -> Bool) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var count = 0
        let maxX = Int(CGFloat(cgImage.width) * maxXFraction)
        for x in stride(from: 0, to: maxX, by: step) {
            for y in stride(from: 0, to: cgImage.height, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }
    func inkWidth(of image: NSImage, pointWidth: CGFloat, threshold: CGFloat = 0.25) -> CGFloat? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cgImage.width > 0 else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        var columns: [Int] = []
        for x in 0..<cgImage.width {
            for y in 0..<cgImage.height {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > threshold {
                    columns.append(x)
                    break
                }
            }
        }
        guard let first = columns.first, let last = columns.last else { return 0 }
        return CGFloat(last - first + 1) * pointWidth / CGFloat(cgImage.width)
    }
    func changedPixelCount(before: NSImage, after: NSImage, step: Int, threshold: CGFloat) -> Int? {
        guard let beforeCG = before.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let afterCG = after.cgImage(forProposedRect: nil, context: nil, hints: nil),
              beforeCG.width == afterCG.width, beforeCG.height == afterCG.height else { return nil }
        let beforeBitmap = NSBitmapImageRep(cgImage: beforeCG)
        let afterBitmap = NSBitmapImageRep(cgImage: afterCG)
        var changed = 0
        for x in stride(from: 0, to: beforeCG.width, by: step) {
            for y in stride(from: 0, to: beforeCG.height, by: step) {
                guard let beforeColor = beforeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let afterColor = afterBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(beforeColor.redComponent - afterColor.redComponent)
                    + abs(beforeColor.greenComponent - afterColor.greenComponent)
                    + abs(beforeColor.blueComponent - afterColor.blueComponent)
                if delta > threshold { changed += 1 }
            }
        }
        return changed
    }
    func assertGrayBorderedUserBubble(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read user bubble pixels.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func color(_ x: Int, _ y: Int) -> NSColor? { bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
        func neutralLuminance(_ color: NSColor) -> CGFloat? {
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard components.max()! - components.min()! < 0.04 else { return nil }
            return components.reduce(0, +) / 3
        }
        var buckets: [Int: Int] = [:]
        var sampled = 0
        var bluePixels = 0
        for x in stride(from: 0, to: cgImage.width, by: 2) {
            for y in stride(from: 0, to: cgImage.height, by: 2) {
                guard let pixel = color(x, y) else { continue }
                sampled += 1
                if pixel.blueComponent > pixel.redComponent + 0.25 && pixel.blueComponent > pixel.greenComponent + 0.1 { bluePixels += 1 }
                if let luminance = neutralLuminance(pixel), luminance < 0.5 { buckets[Int(luminance * 50), default: 0] += 1 }
            }
        }
        XCTAssertEqual(bluePixels, 0, "User messages should no longer render a blue accent bubble.", file: file, line: line)
        guard let (fillBucket, fillCount) = buckets.max(by: { $0.value < $1.value }),
              let background = color(2, cgImage.height - 2).flatMap(neutralLuminance) else {
            XCTFail("The user bubble should have a neutral gray fill over a neutral background.", file: file, line: line)
            return
        }
        let fill = (CGFloat(fillBucket) + 0.5) / 50
        XCTAssertGreaterThan(Double(fillCount) / Double(max(sampled, 1)), 0.3,
                             "The gray fill should dominate the user bubble.", file: file, line: line)
        XCTAssertGreaterThan(fill, background + 0.05,
                             "The bubble fill (\(fill)) should be a lighter gray than the transcript background (\(background)).",
                             file: file, line: line)
        let lightText = pixelCount(in: image, step: 2) { neutralLuminance($0).map { $0 > fill + 0.4 } ?? false }
        XCTAssertGreaterThan(lightText, 20, "User message text should stay light on the gray bubble.", file: file, line: line)
        func edgeIsStroked(_ y: Int, _ xs: [Int]) -> Bool {
            xs.contains { x in color(x, y).flatMap(neutralLuminance).map { $0 > fill + 0.05 && $0 < fill + 0.3 } ?? false }
        }
        let rows = stride(from: cgImage.height * 15 / 100, to: cgImage.height * 65 / 100, by: max(1, cgImage.height / 20))
        let edge = 0..<min(6, cgImage.width)
        XCTAssertTrue(rows.contains { edgeIsStroked($0, Array(edge)) && edgeIsStroked($0, edge.map { cgImage.width - 1 - $0 }) },
                      "The user bubble should have a thin light border on both sides of its gray fill.", file: file, line: line)
    }
    func orangePixelCount(in screenshot: XCUIScreenshot) -> Int {
        pixelCount(in: screenshot.image, where: Self.isOrangePixel)
    }
    func purplePixelCount(in screenshot: XCUIScreenshot) -> Int {
        pixelCount(in: screenshot.image) { color in
            color.blueComponent > 0.5 && color.redComponent > color.greenComponent + 0.15 && color.blueComponent > color.greenComponent + 0.25
        }
    }
}

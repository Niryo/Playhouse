import AppKit
import CoreGraphics
import Darwin
import Foundation
import XCTest
import SQLite3

private struct RunningCLIProcess {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe
}

private final class GitConfigReadBarrier {
    private let configURL: URL
    private let backupURL: URL
    private let contents: Data
    private var writerDescriptor: Int32 = -1
    private var isReleased = false

    init(repositoryURL: URL) throws {
        configURL = repositoryURL.appendingPathComponent(".git/config")
        backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.stationai-test-\(UUID().uuidString)")
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "StationAIUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected an owned regular Git config at \(configURL.path)"])
        }
        contents = try Data(contentsOf: configURL)
        try FileManager.default.moveItem(at: configURL, to: backupURL)
        guard Darwin.mkfifo(configURL.path, mode_t(0o600)) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? FileManager.default.moveItem(at: backupURL, to: configURL)
            throw error
        }
    }

    func waitForReader(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = Darwin.open(configURL.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                writerDescriptor = descriptor
                return
            }
            guard errno == ENXIO else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            usleep(5_000)
        }
        throw NSError(domain: "StationAIUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Git did not open the owned config FIFO: \(configURL.path)"])
    }

    func release() throws {
        guard !isReleased else { return }
        if writerDescriptor < 0, isFIFO(at: configURL) {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let descriptor = Darwin.open(configURL.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    writerDescriptor = descriptor
                    break
                }
                guard errno == ENXIO else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                usleep(5_000)
            }
        }
        if isFIFO(at: configURL) { try FileManager.default.removeItem(at: configURL) }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.moveItem(at: backupURL, to: configURL)
        }
        guard writerDescriptor >= 0 else {
            isReleased = true
            return
        }
        defer {
            Darwin.close(writerDescriptor)
            writerDescriptor = -1
        }
        try contents.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(writerDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }
        isReleased = true
    }

    deinit { try? release() }

    private func isFIFO(at url: URL) -> Bool {
        var fileInfo = Darwin.stat()
        guard Darwin.lstat(url.path, &fileInfo) == 0 else { return false }
        return (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
    }
}

private final class TaskOperationLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL, taskID: String) throws {
        let directory = dataDirectory.appendingPathComponent("task-operation-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(taskID).lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}

private final class TaskStoreWriteLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL) throws {
        let lockURL = dataDirectory.appendingPathComponent("store-write.lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}

private final class ConversationTurnLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL, taskID: String) throws {
        let directory = dataDirectory.appendingPathComponent("conversation-turn-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(taskID).lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}

private final class RepositoryAllocationLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL, repositoryURL: URL) throws {
        let directory = dataDirectory.appendingPathComponent("repository-allocation-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonicalPath = repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonicalPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let lockURL = directory.appendingPathComponent(String(format: "%016llx.lock", hash))
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}

final class StationAIUITests: XCTestCase {
    private static var suiteAbortReason: String?

    private var app: XCUIApplication!
    private var fixture: WorkspaceFixture!
    private var runDirectory: URL!
    private var dataDirectory: URL!
    private var preferencesSuiteName: String!
    private var appBundle: URL!
    private var cliURL: URL!
    private var serviceName: String!
    private var codexFixtureExecutable: String?

    override func setUpWithError() throws {
        if let reason = Self.suiteAbortReason {
            throw XCTSkip("Not run because an earlier case hit a global StationAI startup/focus failure: \(reason)")
        }
        continueAfterFailure = false
        codexFixtureExecutable = nil
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
        clearSavedWindowFrames()
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
        guard runDirectory != nil else { return }
        if let app,
           !terminateAppAndWait(app) {
            XCTFail("StationAI did not stop before UI test data cleanup; preserving the isolated data directory.")
            return
        }
        clearSavedWindowFrames()
        UserDefaults(suiteName: preferencesSuiteName)?.removePersistentDomain(forName: preferencesSuiteName)

        let markerURL = runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker)
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == WorkspaceFixture.ownerContents else {
            XCTFail("Refusing to remove UI test data without its ownership marker: \(runDirectory.path)")
            return
        }
        let testWorktrees = dataDirectory.appendingPathComponent("worktrees", isDirectory: true)
        if FileManager.default.fileExists(atPath: testWorktrees.path) {
            try FileManager.default.removeItem(at: testWorktrees)
            for repository in [fixture.primary, fixture.secondary, fixture.alternate, fixture.changes] {
                try? runGit(repository, "worktree", "prune")
            }
        }
        try FileManager.default.removeItem(at: runDirectory)
    }

    // case-contract: test_service_reports_bridge_version | StationAI opens one main board window and the bridge reports API version 1.
    func test_service_reports_bridge_version() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertEqual(app.windows.count, 1, "StationAI should open one board window on launch.")
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15), "The StationAI window did not open.")
        let response = try runCLI(["status"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["service"] as? String, "StationAI")
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        attachScreenshot(named: "StationAI board opened with a healthy bridge")
    }

    // case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    func test_app_override_rejects_incompatible_bundles() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["STATIONAI_REPOSITORY_ROOT"])
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Protected store", prompt: "Protected draft")
        XCTAssertTrue(terminateAppAndWait(app))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", root + "/scripts/check-app-launch-contract.py", appBundle.path, root, dataDirectory.path]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, text)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Protected store")
        XCTAssertEqual(element("message-composer").value as? String, "Protected draft")
    }

    // case-contract: test_worktree_app_profiles_isolate_identity_and_store | The primary and linked source worktrees resolve to stable, distinct app and XPC identities, build paths, data stores, logs, and managed worktree roots; a saved conversation remains visible after an app restart.
    func test_worktree_app_profiles_isolate_identity_and_store() throws {
        guard let repositoryRoot = ProcessInfo.processInfo.environment["STATIONAI_REPOSITORY_ROOT"] else {
            XCTFail("The UI runner must provide the StationAI source root.")
            return
        }
        let script = URL(fileURLWithPath: repositoryRoot).appendingPathComponent("scripts/app-profile.sh")
        func profile(for worktree: URL) throws -> [String: String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, worktree.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "Failed to resolve the worktree app profile.")
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        }

        let primary = try profile(for: fixture.primary)
        let linked = try profile(for: fixture.existingWorktree)
        XCTAssertEqual(primary["bundleID"], "com.stationai.app")
        XCTAssertEqual(linked["kind"], "linked")
        XCTAssertEqual(linked, try profile(for: fixture.existingWorktree))
        for key in ["bundleID", "bridgeID", "derivedData", "dataDirectory", "logFile", "worktreeRoot"] {
            XCTAssertNotEqual(primary[key], linked[key], "Separate source worktrees must isolate \(key).")
        }
        XCTAssertEqual(linked["bridgeID"], linked["bundleID"].map { $0 + ".bridge" })
        XCTAssertEqual(linked["dataDirectory"], linked["key"].map {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/StationAI/Worktrees/\($0)").path
        })
        let launchedIdentifier = try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier)
        XCTAssertTrue(launchedIdentifier.hasPrefix(try XCTUnwrap(linked["bundleID"]) + ".e2e."))
        XCTAssertEqual(serviceName, launchedIdentifier + ".bridge")
        XCTAssertNotEqual(dataDirectory.path, primary["dataDirectory"])
        XCTAssertNotEqual(dataDirectory.path, linked["dataDirectory"])

        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Worktree profile", prompt: "Keep this draft after restart.")
        XCTAssertEqual(try taskRecord(named: "Worktree profile")?["status"] as? String, "Backlog")
        relaunchApp()
        openTask(named: "Worktree profile")
        XCTAssertEqual(element("message-composer").value as? String, "Keep this draft after restart.")
        let store = dataDirectory.appendingPathComponent("StationAI-v2.store")
        let log = dataDirectory.appendingPathComponent("Diagnostics.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(diagnostics.contains(store.path), "The linked-profile XPC log must name its isolated store.")
        XCTAssertFalse(diagnostics.contains(try XCTUnwrap(primary["dataDirectory"])), "The linked-profile log must not route to the primary store.")
    }

    // case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task immediately opens an empty conversation with the repository picker focused; sending stays disabled until a working folder is added. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
    func test_task_creation_rejects_invalid_title_roots_and_missing_folder() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 10), "New Task should open the repository picker immediately.")
        repositorySearch.typeText("primary")
        XCTAssertEqual(repositorySearch.value as? String, "primary", "Typing after New Task should go directly to the focused repository search.")
        XCTAssertFalse(element("send-message-button").isEnabled, "An empty task without a working folder cannot send a message.")

        assertCLIError(
            try runCLI(["task", "create", "--title", "   ", "--root", fixture.primary.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        let emptyRootTask = try XCTUnwrap(
            try runCLI(["task", "create", "--title", "No roots"])["result"] as? [String: Any]
        )
        XCTAssertEqual(emptyRootTask["workspaceRoots"] as? [String], [])
        XCTAssertTrue(try XCTUnwrap(emptyRootTask["repositoryWorktrees"] as? [[String: Any]]).isEmpty)
        let emptyRootTaskID = try XCTUnwrap(emptyRootTask["id"] as? String)
        let deletedEmptyRootTask = try XCTUnwrap(
            try runCLI(["task", "delete", emptyRootTaskID])["result"] as? [String: Any]
        )
        XCTAssertEqual(deletedEmptyRootTask["deleted"] as? Bool, true)
        assertCLIError(
            try runCLI(
                ["task", "create", "--title", "Missing folder", "--root", fixture.missing.path],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI([
                "task", "create", "--title", "Bad merge target", "--repo", fixture.primary.path,
                "--merge-target", "\(fixture.primary.path)=not-a-local-branch"
            ], expectedStatus: 2),
            code: "invalid_argument"
        )
        closeConversationRepositoryPicker()
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try tasksFromBoardList().count, 0, "Backing out of an empty direct-created task should discard it.")
        attachScreenshot(named: "New Task opens an empty conversation with the repository picker focused")
    }

    // case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A directly created conversation can add repositories in order, edit pending branch settings, and add a context folder; these settings persist across fresh connections without creating branches or worktrees before the first send. Saving an unsent prompt records task creation, prompt save, and subsequent reads with safe argument metadata, result state, and outcome while excluding prompt text.
    func test_task_creation_persists_ordered_roots_across_fresh_connections() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("secondary")
        chooseRepositorySuggestion("primary")
        setConversationRepositoryField("secondary", field: "branch", value: "ordered-roots")
        setConversationRepositoryField("primary", field: "branch", value: "ordered-roots")
        setConversationRepositoryField("secondary", field: "branch-from", value: "branch-source")
        setConversationRepositoryField("primary", field: "branch-from", value: "branch-source")
        setConversationRepositoryField("primary", field: "merge-target", value: "branch-source")
        let editRoots = element("edit-workspace-roots-button")
        assertHelpTag(for: editRoots, equals: "Edit working folders for this task")
        editRoots.click()
        XCTAssertTrue(element("browse-workspace-roots-button").waitForExistence(timeout: 5))
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("save-workspace-roots-button").click()
        let prompt = "PROMPT_TEXT_NOT_IN_DIAGNOSTICS_\(UUID().uuidString)"
        saveNewTaskPromptAndReturnToBoard("Ordered roots", prompt: prompt)
        openTask(named: "Ordered roots")
        let task = try XCTUnwrap(taskRecord(named: "Ordered roots"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        let expectedRoots = try XCTUnwrap(task["workspaceRoots"] as? [String])
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["ordered-roots", "ordered-roots"])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["branch-source", "branch-source"])
        XCTAssertEqual(records.map { $0["mergeTarget"] as? String }, ["main", "branch-source"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(expectedRoots, [fixture.secondary.path, fixture.primary.path, fixture.custom.path])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", "ordered-roots").trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertOrderedRoots(expectedRoots)
        XCTAssertEqual(task["status"] as? String, "Backlog")
        let freshRead = try runCLI(["task", "get", try taskID(named: "Ordered roots")])
        let freshTask = try XCTUnwrap(freshRead["result"] as? [String: Any])
        XCTAssertEqual(freshTask["id"] as? String, task["id"] as? String)
        XCTAssertEqual(freshTask["title"] as? String, task["title"] as? String)
        XCTAssertEqual(freshTask["status"] as? String, task["status"] as? String)
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], expectedRoots)
        let freshRecords = try XCTUnwrap(freshTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(freshRecords.map { $0["repositoryPath"] as? String }, records.map { $0["repositoryPath"] as? String })
        XCTAssertEqual(freshRecords.map { $0["branch"] as? String }, records.map { $0["branch"] as? String })
        XCTAssertEqual(freshRecords.map { $0["worktreePath"] as? String }, records.map { $0["worktreePath"] as? String })

        let events = try diagnosticEvents()
        let serializedDiagnostics = String(data: try JSONSerialization.data(withJSONObject: events), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedDiagnostics.contains(prompt), "Diagnostics must retain prompt metadata without storing the prompt text.")
        let taskCreate = try XCTUnwrap(events.first {
            $0["event"] as? String == "bridge.request.succeeded" && $0["command"] as? String == "task.create"
        })
        XCTAssertEqual(taskCreate["result.status"] as? String, "Backlog")
        XCTAssertNotNil(events.first {
            $0["event"] as? String == "persistence.write.succeeded"
                && ($0["operation"] as? String)?.contains("create(title:repositories:contextFolders:)") == true
        })
        let promptSave = try XCTUnwrap(events.first {
            $0["event"] as? String == "bridge.request.succeeded" && $0["command"] as? String == "task.prompt.save"
        })
        XCTAssertEqual(promptSave["argument.prompt.utf8Bytes"] as? String, String(prompt.utf8.count))
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "persistence.read.succeeded"
                && $0["operation"] as? String == "BoardTaskManager.requireTask"
                && $0["taskID"] as? String == task["id"] as? String
        }, "The log should record a successful task read with its ID.")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "bridge.request.succeeded" && $0["command"] as? String == "board.list"
        }, "The log should record the board read outcome.")

        app.buttons["back-to-board-button"].click()
        relaunchApp()
        openTask(named: "Ordered roots")
        assertOrderedRoots(expectedRoots)
        attachScreenshot(named: "Ordered roots persist across UI and XPC reopen")
    }

    // case-contract: test_task_creation_reuses_existing_branch_worktree | A selected existing branch remains pending until task start, then reuses its exact existing worktree path.
    func test_task_creation_reuses_existing_branch_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        setConversationRepositoryField("primary", field: "branch", value: "ui-existing-worktree")
        saveNewTaskPromptAndReturnToBoard("Reuse existing")
        let task = try XCTUnwrap(taskRecord(named: "Reuse existing"))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.first?["isPending"] as? Bool, true)
        XCTAssertEqual(records.first?["worktreePath"] as? String, fixture.primary.path)
        openTask(named: "Reuse existing")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Reuse existing")
        let started = try XCTUnwrap((taskRecord(named: "Reuse existing")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(started["isPending"] as? Bool, false)
        XCTAssertEqual(started["worktreePath"] as? String, fixture.existingWorktree.path)
        XCTAssertEqual(started["createdByStationAI"] as? Bool, false)
        attachScreenshot(named: "Task start reuses the existing branch worktree")
    }

    // case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | The conversation picker can add multiple repositories; unset branch settings display defaults and persist pending auto records resolved to local main without creating branches or worktrees before the first send.
    func test_task_creation_creates_worktrees_in_multiple_repositories() throws {
        let branchToken = String(UUID().uuidString.prefix(8)).lowercased()
        let taskTitle = "Multi repository UI \(branchToken)"
        let generatedBranch = "multi-repository-ui-\(branchToken)"
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("secondary")
        chooseRepositorySuggestion("primary")
        let pendingTask = try XCTUnwrap(tasksFromBoardList().first)
        let pendingRecords = try XCTUnwrap(pendingTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(pendingRecords.map { $0["branch"] as? String }, ["auto", "auto"])
        saveNewTaskPromptAndReturnToBoard(taskTitle)
        let task = try XCTUnwrap(taskRecord(named: taskTitle))
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branch"] as? String }, ["auto", "auto"])
        XCTAssertEqual(records.map { $0["isPending"] as? Bool }, [true, true])
        XCTAssertEqual(records.map { $0["worktreePath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(records.map { $0["branchFrom"] as? String }, ["main", "main"])
        for repository in [fixture.secondary, fixture.primary] {
            XCTAssertEqual(try runGitOutput(repository, "branch", "--list", generatedBranch).trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        assertTaskVisible(taskTitle, inColumn: "Backlog")
        attachScreenshot(named: "A task has a separate worktree for each selected repository")
    }

    // case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task persists its context without Git worktrees and reaches Done after a successful turn without attempting a merge.
    func test_task_creation_supports_non_git_folder_only_context() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        closeConversationRepositoryPicker()
        element("edit-workspace-roots-button").click()
        XCTAssertTrue(element("browse-workspace-roots-button").waitForExistence(timeout: 5))
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("save-workspace-roots-button").click()
        saveNewTaskPromptAndReturnToBoard("Folder-only UI")
        let task = try XCTUnwrap(taskRecord(named: "Folder-only UI"))
        XCTAssertEqual(((task["repositoryWorktrees"] as? [[String: Any]]) ?? []).count, 0)
        XCTAssertEqual(task["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual(task["workspaceRoots"] as? [String], [fixture.custom.path])
        assertTaskVisible("Folder-only UI", inColumn: "Backlog")
        openTask(named: "Folder-only UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Folder-only UI")
        element("back-to-board-button").click()
        moveTaskToDone("Folder-only UI")
        try assertTaskArchived("Folder-only UI")
        XCTAssertEqual(try taskRecord(named: "Folder-only UI")?["status"] as? String, "Done")
        XCTAssertEqual((try taskRecord(named: "Folder-only UI")?["repositoryWorktrees"] as? [[String: Any]])?.count, 0)
    }

    // case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | Adding a repository branch already assigned to another active task is rejected in the new conversation, and the existing task and repository reservation remain unchanged.
    func test_task_creation_rejects_worktree_assigned_to_active_task() throws {
        launchApp(defaultParent: fixture.parent.path)
        let branch = "active-shared-\(UUID().uuidString.prefix(8).lowercased())"
        let owner = try XCTUnwrap(try runCLI(["task", "create", "--title", "Active owner", "--repo", fixture.primary.path, "--branch", "\(fixture.primary.path)=\(branch)"])["result"] as? [String: Any])
        let ownerID = try XCTUnwrap(owner["id"] as? String)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        let newTask = try XCTUnwrap(tasksFromBoardList().first { $0["id"] as? String != ownerID })
        let newTaskID = try XCTUnwrap(newTask["id"] as? String)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        badge.click()
        element("conversation-repository-branch-edit").click()
        let branchField = element("conversation-repository-branch")
        replaceText(branchField, with: branch)
        element("save-conversation-repository-button").click()
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue((error.label + (error.value as? String ?? "")).contains("already assigned"))
        XCTAssertTrue(branchField.exists, "The user should be able to choose another branch after the conflict.")
        XCTAssertEqual(try repositoryRecord(taskID: ownerID, repositoryPath: fixture.primary.path)?["branch"] as? String, branch)
        XCTAssertEqual(try repositoryRecord(taskID: newTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
        attachScreenshot(named: "An assigned worktree conflict preserves the new conversation repository settings")
    }

    // case-contract: test_task_creation_serializes_repository_branch_reservations | Two concurrent CLI/XPC creates targeting the same explicit branch in one repository serialize through a shared cross-process lock, leaving exactly one persisted active task and rejecting the other.
    func test_task_creation_serializes_repository_branch_reservations() throws {
        launchApp(defaultParent: fixture.parent.path)
        let branch = "concurrent-reservation-\(UUID().uuidString.prefix(8).lowercased())"
        let barrier = try RepositoryAllocationLockBarrier(dataDirectory: dataDirectory, repositoryURL: fixture.primary)
        var barrierReleased = false
        var processes: [RunningCLIProcess] = []
        defer {
            if !barrierReleased { try? barrier.release() }
            for running in processes where running.process.isRunning {
                running.process.terminate()
                running.process.waitUntilExit()
            }
        }

        for title in ["Reservation contender one", "Reservation contender two"] {
            processes.append(try startCLIProcess([
                "task", "create", "--title", title,
                "--repo", fixture.primary.path,
                "--branch", "\(fixture.primary.path)=\(branch)",
            ]))
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(processes.allSatisfy { $0.process.isRunning }, "Both creates should wait on the held repository allocation lock.")
        try barrier.release()
        barrierReleased = true

        let responses = try processes.map { try finishCLIProcess($0, expectedStatus: nil) }
        XCTAssertEqual(processes.map(\.process.terminationStatus).sorted(), [0, 2])
        let successful = responses.filter { $0["ok"] as? Bool == true }
        let rejected = try XCTUnwrap(responses.first { $0["ok"] as? Bool == false })
        XCTAssertEqual(successful.count, 1)
        assertCLIError(rejected, code: "invalid_argument")
        XCTAssertTrue(((rejected["error"] as? [String: Any])?["message"] as? String ?? "").contains("already assigned"))

        let tasks = try tasksFromBoardList()
        XCTAssertEqual(tasks.count, 1)
        let taskID = try XCTUnwrap(tasks.first?["id"] as? String)
        let record = try XCTUnwrap((taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["branch"] as? String, branch)
        XCTAssertEqual(record["isPending"] as? Bool, true)
        let card = element("task-card-\(taskID.uppercased())")
        XCTAssertTrue(waitUntil({ card.exists }, timeout: 10), "Exactly one reservation should appear on the visible board.")
        card.click()
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
    }

    // case-contract: test_persistence_store_open_failure_records_detailed_error | A real ModelContainer open failure against an isolated invalid store path returns an error and durably logs the phase, exact underlying NSError domain/code/userInfo, resolved store path, file/sidecar snapshot, and read-only schema probe failure; the paired visible UI case keeps StationAI open on its normal board while the same isolated CLI/XPC request fails and verifies the persisted diagnostic.
    func test_persistence_store_open_failure_records_detailed_error() throws {
        launchApp(defaultParent: fixture.parent.path)
        let failureDirectory = dataDirectory.appendingPathComponent("invalid-store-open", isDirectory: true)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let store = failureDirectory.appendingPathComponent("StationAI-v2.store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)

        let failedResponse = try runCLI(
            ["task", "list"],
            expectedStatus: 1,
            extraEnvironment: ["STATIONAI_DATA_DIRECTORY": failureDirectory.path]
        )
        XCTAssertEqual(failedResponse["ok"] as? Bool, false)
        let diagnosticPath = failureDirectory.appendingPathComponent("Diagnostics.jsonl")
        let log = try String(contentsOf: diagnosticPath, encoding: .utf8)
        let events = try log.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failedOpen = try XCTUnwrap(events.first { $0["event"] as? String == "persistence.store.open.failed" })
        XCTAssertEqual(failedOpen["phase"] as? String, "model-container-open")
        XCTAssertEqual(failedOpen["storePath"] as? String, store.path)
        XCTAssertEqual(failedOpen["storeFileExists"] as? String, "true")
        XCTAssertNotNil(failedOpen["storeWALExists"] as? String)
        XCTAssertNotNil(failedOpen["storeSHMExists"] as? String)
        XCTAssertNotNil(failedOpen["errorDescription"] as? String)
        XCTAssertNotNil(failedOpen["error0Domain"] as? String)
        XCTAssertNotNil(failedOpen["error0Code"] as? String)
        XCTAssertNotNil(failedOpen["error0UserInfoKeys"] as? String)
        XCTAssertNotNil(failedOpen["error0UserInfoKeyCount"] as? String)
        XCTAssertNotNil(failedOpen["error0UserInfo"] as? String)
        XCTAssertEqual(failedOpen["schemaProbeResult"] as? String, "open-failed")
        XCTAssertNotNil(failedOpen["schemaProbeSQLiteMessage"] as? String)
        XCTAssertEqual(app.state, .runningForeground, "The normal StationAI app should remain open after the isolated CLI failure.")
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5), "The normal board should remain visible after the isolated CLI failure.")
    }

    // case-contract: test_persistence_read_failure_records_detailed_error | A real SwiftData fetch failure against an isolated store with a missing task column returns an error and logs a correlated read ID, NSError domain/code/userInfo, store path, file/sidecar snapshot, and the exact missing-column message from a read-only schema probe before the CLI/XPC request completes; the paired visible UI case keeps the normal task board open and verifies the same isolated failure record.
    func test_persistence_read_failure_records_detailed_error() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        let failureDirectory = dataDirectory.appendingPathComponent("fetch-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        _ = try runCLI(
            ["task", "create", "--title", "Missing column read failure", "--root", fixture.primary.path],
            extraEnvironment: ["STATIONAI_DATA_DIRECTORY": failureDirectory.path]
        )
        let store = failureDirectory.appendingPathComponent("StationAI-v2.store")
        let corrupt = Process()
        corrupt.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        corrupt.arguments = [store.path, "ALTER TABLE ZBOARDTASK DROP COLUMN ZPROGRESSLABEL"]
        let corruptOutput = Pipe()
        corrupt.standardOutput = corruptOutput
        corrupt.standardError = corruptOutput
        try corrupt.run()
        corrupt.waitUntilExit()
        let corruptionDetails = String(
            data: corruptOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        XCTAssertEqual(corrupt.terminationStatus, 0, "The isolated test store should lose its progress label column: \(corruptionDetails)")

        let failedResponse = try runCLI(
            ["task", "list"],
            expectedStatus: 1,
            extraEnvironment: ["STATIONAI_DATA_DIRECTORY": failureDirectory.path]
        )
        XCTAssertEqual(failedResponse["ok"] as? Bool, false)
        let diagnosticPath = failureDirectory.appendingPathComponent("Diagnostics.jsonl")
        let log = try String(contentsOf: diagnosticPath, encoding: .utf8)
        let events = try log.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failedRead = try XCTUnwrap(events.first {
            $0["event"] as? String == "persistence.read.failed"
                && $0["operation"] as? String == "BoardTaskManager.list"
        })
        let readID = try XCTUnwrap(failedRead["readID"] as? String)
        XCTAssertEqual(failedRead["storePath"] as? String, store.path)
        XCTAssertEqual(failedRead["storeFileExists"] as? String, "true")
        XCTAssertNotNil(failedRead["storeWALExists"] as? String)
        XCTAssertNotNil(failedRead["storeSHMExists"] as? String)
        XCTAssertNotNil(failedRead["errorDescription"] as? String)
        XCTAssertNotNil(failedRead["error0Domain"] as? String)
        XCTAssertNotNil(failedRead["error0Code"] as? String)
        XCTAssertNotNil(failedRead["error0UserInfoKeys"] as? String)
        XCTAssertNotNil(failedRead["error0UserInfoKeyCount"] as? String)
        XCTAssertNotNil(failedRead["error0UserInfo"] as? String)
        XCTAssertEqual(failedRead["schemaProbeResult"] as? String, "prepare-failed")
        XCTAssertEqual(failedRead["schemaProbeSQLiteCode"] as? String, "1")
        XCTAssertTrue((failedRead["schemaProbeSQLiteMessage"] as? String)?.contains("no such column: t0.ZPROGRESSLABEL") == true)
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "persistence.read.started"
                && $0["readID"] as? String == readID
                && $0["storePath"] as? String == store.path
        }, "The error should correlate to its started store read.")
        XCTAssertEqual(app.state, .runningForeground, "The normal app should stay open while the isolated bridge store fails.")
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5), "The normal app board should stay available while the isolated bridge store fails.")
    }

    // case-contract: test_legacy_store_import_failure_preserves_original | An invalid legacy database fails import without changing the source or publishing a destination or partial snapshot; the normal isolated board remains usable.
    func test_legacy_store_import_failure_preserves_original() throws {
        launchApp(defaultParent: fixture.parent.path)
        let failure = dataDirectory.appendingPathComponent("invalid-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: failure, withIntermediateDirectories: true)
        let source = failure.appendingPathComponent("StationAI.store")
        let contents = Data("Not a SQLite database".utf8)
        try contents.write(to: source)
        let response = try runCLI(["task", "list"], expectedStatus: 1, extraEnvironment: ["STATIONAI_DATA_DIRECTORY": failure.path])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.appendingPathComponent("StationAI-v2.store").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: failure.path).contains { $0.hasPrefix(".store-import-") })
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Healthy board", prompt: "Still usable")
        openTask(named: "Healthy board")
        XCTAssertEqual(element("message-composer").value as? String, "Still usable")
    }

    // case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with old model metadata and no submitted-prompt column waits for the store-write lock while app and CLI/XPC open concurrently, is backed up before migration, and preserves its task and draft after a visible restart; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only draft data survives import, and a subsequent edited draft survives restart without reimport.
    func test_task_store_repairs_missing_pending_prompt_column() throws {
        let title = "Legacy pending prompt store"
        let draft = "Committed WAL draft must survive import."
        let seeder = WorkspaceFixture.root.appendingPathComponent("seed-legacy-task-store")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: seeder.path))
        let seed = Process()
        seed.executableURL = seeder
        seed.arguments = [dataDirectory.path]
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seeded = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, seeded)
        let taskID = seeded.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = dataDirectory.appendingPathComponent("StationAI-v2.store")
        let legacyStore = dataDirectory.appendingPathComponent("StationAI.store")
        func sqlite(_ statement: String, at databaseURL: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [databaseURL.path, statement]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "SQLite fixture operation failed: \(text)")
            return text
        }
        XCTAssertFalse(try sqlite("PRAGMA table_info(ZBOARDTASK)", at: legacyStore).contains("ZPENDINGSUBMITTEDPROMPT"))
        XCTAssertEqual(try sqlite("SELECT count(*) FROM ZBOARDTASK", at: legacyStore).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let legacyMetadata = try sqlite("SELECT hex(Z_PLIST) FROM Z_METADATA", at: legacyStore)
        var wal: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyStore.path, &wal), SQLITE_OK)
        defer { sqlite3_close(wal) }
        XCTAssertEqual(sqlite3_exec(wal, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE ZBOARDTASK SET ZSAVEDPROMPT='Committed WAL draft must survive import.'", nil, nil, nil), SQLITE_OK)
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: legacyStore.path + "-wal")).count, 0)
        let legacyBytes = try Data(contentsOf: legacyStore)

        let writeBarrier = try TaskStoreWriteLockBarrier(dataDirectory: dataDirectory)
        defer { try? writeBarrier.release() }
        let pendingRead = try startCLIProcess(["task", "get", taskID])
        XCTAssertTrue(waitUntil({
            guard let events = try? self.diagnosticEvents() else { return false }
            return events.contains { $0["event"] as? String == "persistence.store.schema_migration.waiting_for_write_lock" }
        }, timeout: 15), "The XPC opener should wait for the held store-write lock.")
        XCTAssertTrue(pendingRead.process.isRunning)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [
            "-n",
            "--env", "STATIONAI_DATA_DIRECTORY=\(dataDirectory.path)",
            "--env", "STATIONAI_E2E_WORKTREE_DIRECTORY=\(dataDirectory.appendingPathComponent("worktrees").path)",
            "--env", "STATIONAI_E2E_DEFAULTS_SUITE=\(preferencesSuiteName!)",
            "--env", "STATIONAI_E2E_DEFAULT_PARENT_FOLDER=\(fixture.parent.path)",
            appBundle.path
        ]
        let openOutput = Pipe()
        opener.standardOutput = openOutput
        opener.standardError = openOutput
        try opener.run()
        app = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: appBundle)?.bundleIdentifier))
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        app.launchEnvironment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        app.launchEnvironment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = fixture.parent.path
        XCTAssertTrue(waitUntil({
            guard let events = try? self.diagnosticEvents() else { return false }
            return events.contains {
                $0["event"] as? String == "persistence.store.schema_migration.waiting_for_schema_lock"
                    && $0["process"] as? String == "StationAI"
            }
        }, timeout: 15), "The visible app should reach the old store while XPC holds its schema lock.")
        XCTAssertTrue(pendingRead.process.isRunning)
        try writeBarrier.release()
        opener.waitUntilExit()
        XCTAssertEqual(opener.terminationStatus, 0, String(data: openOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let concurrentRead = try finishCLIProcess(pendingRead)
        XCTAssertEqual((concurrentRead["result"] as? [String: Any])?["savedPrompt"] as? String, draft)
        app.activate()
        waitForBoardOrAbortSuite()
        assertTaskVisible(title, inColumn: "Backlog")
        let backups = try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("StationAI.store.before-pending-prompt-") && $0.pathExtension == "backup" }
        XCTAssertEqual(backups.count, 1)
        if let backup = backups.first {
            XCTAssertEqual(try sqlite("PRAGMA quick_check", at: backup).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            XCTAssertEqual(try sqlite("SELECT count(*) FROM ZBOARDTASK", at: backup).trimmingCharacters(in: .whitespacesAndNewlines), "1")
            XCTAssertFalse(try sqlite("PRAGMA table_info(ZBOARDTASK)", at: backup).contains("ZPENDINGSUBMITTEDPROMPT"))
        }
        XCTAssertEqual(try sqlite("PRAGMA table_info(ZBOARDTASK)", at: store).contains("ZPENDINGSUBMITTEDPROMPT"), true)
        XCTAssertNotEqual(try sqlite("SELECT hex(Z_PLIST) FROM Z_METADATA", at: store), legacyMetadata)
        XCTAssertEqual(try Data(contentsOf: legacyStore), legacyBytes)
        let migrationEvents = try diagnosticEvents()
        XCTAssertTrue(migrationEvents.contains { $0["event"] as? String == "persistence.store.schema_migration.write_lock_acquired" })
        XCTAssertFalse(migrationEvents.contains {
            ["persistence.store.open.failed", "persistence.read.failed"].contains($0["event"] as? String ?? "")
        })
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, draft)
        openTask(named: title)
        XCTAssertEqual(element("message-composer").value as? String, draft)

        let composer = element("message-composer")
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("Edited after import")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, "Edited after import")
        XCTAssertTrue(terminateAppAndWait(app))
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible(title, inColumn: "Backlog")
        openTask(named: title)
        XCTAssertEqual(element("message-composer").value as? String, "Edited after import")
        XCTAssertEqual(try diagnosticEvents().filter { $0["event"] as? String == "persistence.store.legacy_imported" }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("StationAI.store.before-pending-prompt-") && $0.pathExtension == "backup" }.count, 1)
    }

    // case-contract: test_test_bundle_rejects_unisolated_data_directory | A test-built StationAI service rejects a data directory outside the temporary test area and a linked store inside it before creating or opening either store; the visible app remains on its isolated board and can still read its tasks.
    func test_test_bundle_rejects_unisolated_data_directory() throws {
        launchApp(defaultParent: fixture.parent.path)
        let title = "Isolated board remains available"
        let created = try runCLI(["task", "create", "--title", title])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        assertTaskVisible(title, inColumn: "Backlog")

        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let unsafe = caches.appendingPathComponent("StationAI-bridge-guard-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.path))
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        let marker = unsafe.appendingPathComponent(".stationai-test-owner")
        try "StationAI bridge guard test (v1).\n".write(to: marker, atomically: true, encoding: .utf8)
        defer {
            if (try? String(contentsOf: marker, encoding: .utf8)) == "StationAI bridge guard test (v1).\n" {
                try? FileManager.default.removeItem(at: unsafe)
            } else {
                XCTFail("Refusing to remove a guard fixture without its ownership marker.")
            }
        }
        let denied = try runCLI(
            ["board", "list"], expectedStatus: 1,
            extraEnvironment: ["STATIONAI_DATA_DIRECTORY": unsafe.path]
        )
        XCTAssertEqual(denied["error"] as? [String: String], [
            "code": "operation_failed",
            "message": "A StationAI test bundle requires an isolated temporary data directory."
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("StationAI-v2.store").path))
        let linked = dataDirectory.appendingPathComponent("linked-store", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("StationAI-v2.store"),
            withDestinationURL: unsafe.appendingPathComponent("StationAI-v2.store")
        )
        let linkedDenied = try runCLI(
            ["board", "list"], expectedStatus: 1,
            extraEnvironment: ["STATIONAI_DATA_DIRECTORY": linked.path]
        )
        XCTAssertEqual(linkedDenied["error"] as? [String: String], [
            "code": "operation_failed",
            "message": "A StationAI test bundle cannot open a linked task store."
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("StationAI-v2.store").path))
        XCTAssertEqual(try taskRecord(id: taskID)?["title"] as? String, title)
        assertTaskVisible(title, inColumn: "Backlog")
    }

    // case-contract: test_task_store_serializes_cross_process_writes | If another process holds the shared task-store write lock when a Codex turn completes, final status persistence waits and then saves Review status and full history across fresh CLI/XPC reads. Correlated persistence diagnostics include task ID, store path, lock wait, attempts, and retry count; task reads correlate started and completed events by read ID and store path, while failed reads include store file and sidecar state. Reopening the conversation in the UI shows the saved exchange without a store error.
    func test_task_store_serializes_cross_process_writes() throws {
        let fixtureExecutable = dataDirectory.appendingPathComponent("codex-fixture-store-write-success-wait")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureExecutable.path), "A unique per-case fixture must not replace an existing file.")
        try FileManager.default.copyItem(
            at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-success-wait"),
            to: fixtureExecutable
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixtureExecutable.path)
        try "StationAI test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".stationai-codex-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )

        let title = "Store write contention"
        let created = try XCTUnwrap(
            try runCLI(["task", "create", "--title", title, "--repo", fixture.primary.path])["result"] as? [String: Any]
        )
        let taskID = try XCTUnwrap(created["id"] as? String)
        codexFixtureExecutable = fixtureExecutable.path
        let prompt = "Persist this completed turn."
        let process = try startCLIProcess(
            ["conversation", "send", taskID, "--message", prompt],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureExecutable.path]
        )
        let ready = URL(fileURLWithPath: fixtureExecutable.path + ".resolve-ready")
        let continuation = URL(fileURLWithPath: fixtureExecutable.path + ".resolve-continue")
        var barrier: TaskStoreWriteLockBarrier?
        var barrierReleased = false
        defer {
            if !barrierReleased { try? barrier?.release() }
            if process.process.isRunning {
                process.process.terminate()
                process.process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The app-server fixture should pause during the active Codex turn.")
        barrier = try TaskStoreWriteLockBarrier(dataDirectory: dataDirectory)
        try "Release the completed fixture turn.\n".write(to: continuation, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "codex.turn.ended"
                    && $0["threadID"] as? String == "00000000-0000-0000-0000-000000000001"
                    && $0["turnStatus"] as? String == "completed"
            }) == true
        }, timeout: 15), "Codex should finish before the task's final status save.")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(process.process.isRunning, "Final task status persistence should wait for the shared store write lock.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")

        try barrier?.release()
        barrierReleased = true
        let response = try finishCLIProcess(process)
        XCTAssertEqual(response["ok"] as? Bool, true)
        let finalTask = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(finalTask["status"] as? String, "Review")
        XCTAssertNil(finalTask["pendingSubmittedPrompt"] as? String)
        let history = try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureExecutable.path]
        )["result"] as? [String: Any]
        let messages = try XCTUnwrap(history?["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { $0["role"] as? String == "user" && $0["text"] as? String == prompt })
        XCTAssertTrue(messages.contains {
            $0["role"] as? String == "assistant" && $0["text"] as? String == "Answers received: Blue / fixture-secret."
        })
        let lockEvents = try diagnosticEvents().filter {
            $0["taskID"] as? String == taskID && $0["event"] as? String == "persistence.write.lock_acquired"
        }
        let waitedWrite = try XCTUnwrap(lockEvents.first {
            (Int($0["lockWaitMilliseconds"] as? String ?? "0") ?? 0) > 0
        }, "The final task write should log its wait for the shared store lock.")
        XCTAssertEqual(waitedWrite["storePath"] as? String, dataDirectory.appendingPathComponent("StationAI-v2.store").path)
        let waitedWriteID = try XCTUnwrap(waitedWrite["writeID"] as? String)
        let matchingWrite = try XCTUnwrap(try diagnosticEvents().first {
            $0["taskID"] as? String == taskID
                && $0["event"] as? String == "persistence.write.succeeded"
                && $0["writeID"] as? String == waitedWriteID
        })
        XCTAssertEqual(matchingWrite["attemptCount"] as? String, "1")
        XCTAssertEqual(matchingWrite["retryCount"] as? String, "0")

        let readEvents = try diagnosticEvents().filter {
            $0["taskID"] as? String == taskID
                && $0["operation"] as? String == "BoardTaskManager.requireTask"
                && ["persistence.read.started", "persistence.read.succeeded"].contains($0["event"] as? String ?? "")
        }
        let successfulRead = try XCTUnwrap(readEvents.first { $0["event"] as? String == "persistence.read.succeeded" })
        let readID = try XCTUnwrap(successfulRead["readID"] as? String)
        let matchingReadStart = try XCTUnwrap(readEvents.first {
            $0["event"] as? String == "persistence.read.started" && $0["readID"] as? String == readID
        })
        let expectedStorePath = dataDirectory.appendingPathComponent("StationAI-v2.store").path
        let snapshotPrefixes = ["storeDirectory", "storeFile", "storeWAL", "storeSHM"]
        for readEvent in [matchingReadStart, successfulRead] {
            XCTAssertEqual(readEvent["storePath"] as? String, expectedStorePath)
            for key in readEvent.keys {
                XCTAssertFalse(snapshotPrefixes.contains { key.hasPrefix($0) }, "Successful read events should omit filesystem snapshot field \(key).")
            }
        }
        XCTAssertNotNil(successfulRead["durationMilliseconds"] as? String)

        launchApp(defaultParent: fixture.parent.path)
        openTask(named: title)
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 10), "The saved user message should render after reopening the conversation.")
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10), "The saved assistant reply should render after reopening the conversation.")
        XCTAssertFalse(element("codex-chat-error").exists, "A recovered store write must not leave a conversation error banner.")
        attachScreenshot(named: "Conversation status and history persist after shared store contention")
    }

    // case-contract: test_task_worktree_preparation_serializes_auto_branch_claims | Tasks with the same automatic branch choice remain pending without creating a worktree before conversation start; the opt-in live Codex integration sends both turns concurrently and confirms only one task claims the generated branch.
    func test_task_worktree_preparation_serializes_auto_branch_claims() throws {
        launchApp(defaultParent: fixture.parent.path)
        let existingWorktreeCount = try runGitOutput(fixture.primary, "worktree", "list", "--porcelain")
            .components(separatedBy: "worktree ").count - 1
        let title = "Concurrent auto branch \(UUID().uuidString.prefix(8).lowercased())"
        var taskIDs: [String] = []
        for _ in 0..<2 {
            let created = try runCLI(["task", "create", "--title", title, "--repo", fixture.primary.path])["result"] as? [String: Any]
            taskIDs.append(try XCTUnwrap(created?["id"] as? String))
        }

        let isLiveIntegration = FileManager.default.fileExists(atPath: "/tmp/stationai-codex-live-ui-integration")
        if isLiveIntegration {
            let barrier = try RepositoryAllocationLockBarrier(dataDirectory: dataDirectory, repositoryURL: fixture.primary)
            var barrierReleased = false
            var processes: [RunningCLIProcess] = []
            defer {
                if !barrierReleased { try? barrier.release() }
                for running in processes where running.process.isRunning {
                    running.process.terminate()
                    running.process.waitUntilExit()
                }
            }

            for taskID in taskIDs {
                processes.append(try startCLIProcess([
                    "conversation", "send", taskID, "--message",
                    "Inspect the repository and respond exactly READY. Do not change any files.", "--mode", "plan",
                ]))
            }
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(processes.allSatisfy { $0.process.isRunning }, "Both live Codex turns should wait before preparing their shared auto branch.")
            try barrier.release()
            barrierReleased = true

            let responses = try processes.map { try finishCLIProcess($0, expectedStatus: nil) }
            XCTAssertEqual(processes.map(\.process.terminationStatus).sorted(), [0, 2])
            let rejected = try XCTUnwrap(responses.first { $0["ok"] as? Bool == false })
            XCTAssertEqual(responses.filter { $0["ok"] as? Bool == true }.count, 1)
            assertCLIError(rejected, code: "invalid_argument")
            XCTAssertTrue(((rejected["error"] as? [String: Any])?["message"] as? String ?? "").contains("already assigned"))
        }

        let tasks = try taskIDs.map { try XCTUnwrap(taskRecord(id: $0)) }
        if !isLiveIntegration {
            XCTAssertTrue(tasks.allSatisfy { (($0["repositoryWorktrees"] as? [[String: Any]])?.first?["isPending"] as? Bool) == true })
            XCTAssertTrue(tasks.allSatisfy { ($0["repositoryWorktrees"] as? [[String: Any]])?.first?["branch"] as? String == "auto" })
            XCTAssertTrue(tasks.allSatisfy { ($0["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String == fixture.primary.path })
            XCTAssertTrue(tasks.allSatisfy { $0["status"] as? String == "Backlog" })
            XCTAssertEqual(
                try runGitOutput(fixture.primary, "worktree", "list", "--porcelain").components(separatedBy: "worktree ").count - 1,
                existingWorktreeCount,
                "Same-title pending tasks must not reserve a branch or create worktrees before their first conversation turn."
            )
            for taskID in taskIDs {
                let card = element("task-card-\(taskID.uppercased())")
                XCTAssertTrue(card.waitForExistence(timeout: 10), "Pending tasks should remain visible on the board before conversation start.")
            }
            return
        }

        let prepared = try XCTUnwrap(tasks.first { (($0["repositoryWorktrees"] as? [[String: Any]])?.first?["isPending"] as? Bool) == false })
        let pending = try XCTUnwrap(tasks.first { (($0["repositoryWorktrees"] as? [[String: Any]])?.first?["isPending"] as? Bool) == true })
        let preparedRecord = try XCTUnwrap((prepared["repositoryWorktrees"] as? [[String: Any]])?.first)
        let pendingRecord = try XCTUnwrap((pending["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(prepared["status"] as? String, "Review")
        XCTAssertEqual(pending["status"] as? String, "Backlog")
        XCTAssertEqual(pendingRecord["branch"] as? String, "auto")
        XCTAssertEqual(pendingRecord["worktreePath"] as? String, fixture.primary.path)
        let worktreePath = try XCTUnwrap(preparedRecord["worktreePath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))
        let worktreeRoot = dataDirectory.appendingPathComponent("worktrees", isDirectory: true).standardizedFileURL.path + "/"
        XCTAssertTrue(URL(fileURLWithPath: worktreePath).standardizedFileURL.path.hasPrefix(worktreeRoot))
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "worktree", "list", "--porcelain").components(separatedBy: "worktree ").count - 1,
            existingWorktreeCount + 1
        )

        let visibleID = try XCTUnwrap(prepared["id"] as? String)
        let card = element("task-card-\(visibleID.uppercased())")
        XCTAssertTrue(waitUntil({ card.exists }, timeout: 10), "Only the task with the prepared worktree should be visible in Review.")
        card.click()
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
    }

    // case-contract: test_task_done_preserves_worktree_and_branch | Sending the first message derives an auto branch from the generated task title. Moving a reviewed task to Done waits for active per-task operations and persists against refreshed state; it preserves that source branch and worktree without merging into the local target, retains conversation history, and exposes the task in the searchable read-only archive.
    func test_task_done_preserves_worktree_and_branch() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        XCTAssertTrue(element("message-composer").waitForExistence(timeout: 10), "New Task should open the composer in its conversation.")
        let task = try XCTUnwrap(tasksFromBoardList().first)
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        var path = try XCTUnwrap(record["worktreePath"] as? String)
        var branch = try XCTUnwrap(record["branch"] as? String)
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertEqual(branch, "auto")
        XCTAssertEqual(record["isPending"] as? Bool, true)
        XCTAssertEqual(path, fixture.primary.path)
        let taskPrompt = "Please update the README and add concise setup steps for first time contributors tomorrow."
        let generatedBranch = "generated-fixture-title"
        XCTAssertEqual(record["mergeTarget"] as? String, "main")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.isEnabled && composer.isHittable }, timeout: 15), "The composer should become available after conversation history loads.")
        composer.click()
        composer.typeText(taskPrompt)
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        let startedRecord = try XCTUnwrap((taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(startedRecord["isPending"] as? Bool, false)
        path = try XCTUnwrap(startedRecord["worktreePath"] as? String)
        branch = try XCTUnwrap(startedRecord["branch"] as? String)
        XCTAssertNotEqual(path, fixture.primary.path)
        XCTAssertEqual(branch, generatedBranch)
        let taskBranchHead = try runGitOutput(URL(fileURLWithPath: path), "rev-parse", "HEAD")
        let originalTargetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        XCTAssertEqual(taskBranchHead, originalTargetHead)
        try "Master advanced after this task branch was created.\n".write(
            to: fixture.primary.appendingPathComponent("target-only.txt"), atomically: true, encoding: .utf8
        )
        try runGit(fixture.primary, "add", "target-only.txt")
        try runGit(fixture.primary, "commit", "-m", "Advance merge target while task is under review")
        let targetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        element("back-to-board-button").click()
        let titleDeadline = Date().addingTimeInterval(20)
        var currentTitle = "Generating title…"
        while Date() < titleDeadline, currentTitle == "Generating title…" {
            currentTitle = try XCTUnwrap(taskRecord(id: taskID)?["title"] as? String)
            if currentTitle == "Generating title…" { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        }
        XCTAssertNotEqual(currentTitle, "Generating title…", "The title placeholder should eventually resolve.")
        let moveLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var moveLockReleased = false
        defer { if !moveLockReleased { try? moveLock.release() } }
        let taskCard = element("task-card-\(taskID)")
        XCTAssertTrue(taskCard.waitForExistence(timeout: 5))
        dragTaskToDone(taskCard)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "The UI move should wait while another process owns the task operation lock.")
        try moveLock.release()
        moveLockReleased = true
        XCTAssertTrue(waitUntil({ !element("task-card-\(taskID)").exists }, timeout: 15), "The completed task should disappear from the active board.")
        XCTAssertEqual(element("task-count").value as? String, "0", "The active task count should decrease when a task is archived.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, taskPrompt)
        XCTAssertEqual(try runCLI(["task", "move", taskID, "Done"])["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Moving a task to Done must preserve its worktree.")
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead, "Moving a task to Done must not merge into the local target.")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent("target-only.txt"), encoding: .utf8), "Master advanced after this task branch was created.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.primary.appendingPathComponent("task-result.txt").path))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")

        let titleMatch = try XCTUnwrap(try runCLI(["task", "create", "--title", "fixture-secret title match", "--root", fixture.custom.path])["result"] as? [String: Any])
        let titleMatchID = try XCTUnwrap(titleMatch["id"] as? String)
        let fixtureExecutable = try XCTUnwrap(codexFixtureExecutable)
        _ = try runCLI(
            ["conversation", "send", titleMatchID, "--message", "Another completed conversation.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureExecutable]
        )
        XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", titleMatchID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")

        let archiveButton = element("done-archive-button")
        assertHelpTag(for: archiveButton, equals: "Browse completed tasks")
        archiveButton.click()
        let archiveResult = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archiveResult.waitForExistence(timeout: 10), "The completed task should appear in the archive.")
        assertHelpTag(for: archiveResult, equals: "Open task: \(currentTitle)")
        let archiveSearch = element("done-archive-search")
        archiveSearch.click()
        archiveSearch.typeText("no-such-archive-task")
        XCTAssertTrue(element("done-archive-empty-state").waitForExistence(timeout: 10), "A search with no matches should show an empty state.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("FiXtUrE-SeCrEt")
        let titleMatchResult = element("done-archive-task-\(titleMatchID)")
        XCTAssertTrue(titleMatchResult.waitForExistence(timeout: 10), "A title match should appear in the archive search results.")
        XCTAssertTrue(archiveResult.waitForExistence(timeout: 10), "Searching saved conversation text should find the completed task.")
        XCTAssertLessThan(titleMatchResult.frame.minY, archiveResult.frame.minY, "Title matches should precede conversation-only matches.")
        archiveResult.click()
        XCTAssertTrue(element("archived-conversation-read-only").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertFalse(element("message-composer").exists, "Archived conversations must not expose the composer.")
        XCTAssertFalse(element("edit-workspace-roots-button").isEnabled, "Archived conversations must not allow workspace edits.")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done", "Leaving the read-only conversation must not alter the archived task.")
        attachScreenshot(named: "Completed task opens from the searchable read-only archive")
    }

    // case-contract: test_task_done_preserves_dirty_worktree | Moving a reviewed task to Done changes only task status and preserves dirty worktree files, branch, and target commit without committing or merging.
    func test_task_done_preserves_dirty_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Dirty done UI", "--repo", fixture.primary.path])
        openTask(named: "Dirty done UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Dirty done UI")
        element("back-to-board-button").click()
        let record = try XCTUnwrap((taskRecord(named: "Dirty done UI")?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let path = try XCTUnwrap(record["worktreePath"] as? String)
        let branch = try XCTUnwrap(record["branch"] as? String)
        try "Edited after review\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("stationai-primary.txt"), atomically: true, encoding: .utf8)
        try "New unsaved work\n".write(to: URL(fileURLWithPath: path).appendingPathComponent("unsaved.txt"), atomically: true, encoding: .utf8)
        let targetBefore = try runGitOutput(fixture.primary, "rev-parse", "main")
        let branchHead = try runGitOutput(URL(fileURLWithPath: path), "rev-parse", "HEAD")
        moveTaskToDone("Dirty done UI")
        try assertTaskArchived("Dirty done UI")
        XCTAssertEqual(try taskRecord(named: "Dirty done UI")?["status"] as? String, "Done")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Done must preserve the task worktree.")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("stationai-primary.txt"), encoding: .utf8), "Edited after review\n")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("unsaved.txt"), encoding: .utf8), "New unsaved work\n")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetBefore)
        XCTAssertEqual(try runGitOutput(URL(fileURLWithPath: path), "rev-parse", "HEAD"), branchHead)
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)")
        attachScreenshot(named: "Done preserves the task worktree without merging")
    }

    // case-contract: test_task_pr_create_reports_real_gh_failure | A repository-backed task exposes an active-card PR action and a Done-task archive PR action with distinct hover emphasis and useful help; it preserves the configured merge target, waits for the task operation lock, commits and publishes the branch before GitHub lookup, and reports publication failure without saving a PR link or changing Done status when no usable remote exists.
    func test_task_pr_create_reports_real_gh_failure() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR failure UI", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        let createdRecord = try XCTUnwrap((created["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(createdRecord["mergeTarget"] as? String, "main")
        openTask(named: "PR failure UI")
        element("conversation-repository-badge-primary").click()
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(mergeTargetValue.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "main")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR failure UI")
        element("back-to-board-button").click()
        let activeCreateButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(activeCreateButton.waitForExistence(timeout: 5), "An active repository task should expose its PR action on the card.")
        assertHoverEmphasis(for: activeCreateButton)
        assertHelpTag(for: activeCreateButton, equals: "Create a pull request for each repository linked to this task")
        moveTaskToDone(taskID: taskID)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")
        element("done-archive-button").click()
        let archiveTask = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archiveTask.waitForExistence(timeout: 10), "The completed task should be listed in the archive.")
        let createButton = element("done-archive-create-pr-\(taskID)")
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        assertHoverEmphasis(for: createButton)
        assertHelpTag(for: createButton, equals: "Create a pull request for each repository linked to this completed task")
        let operationLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var operationLockReleased = false
        defer { if !operationLockReleased { try? operationLock.release() } }
        createButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertFalse(app.sheets.firstMatch.exists, "The UI should wait on the task operation lock before starting the real gh lookup.")
        let waitingTask = try XCTUnwrap(taskRecord(id: taskID))
        let waitingRecord = try XCTUnwrap((waitingTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(waitingTask["status"] as? String, "Done")
        XCTAssertNil(waitingRecord["pullRequestNumber"])
        XCTAssertNil(waitingRecord["pullRequestURL"])
        try operationLock.release()
        operationLockReleased = true
        let alertSheet = app.sheets.firstMatch
        XCTAssertTrue(alertSheet.waitForExistence(timeout: 20), "The archived task should report gh's inability to create a PR.")
        XCTAssertTrue(element(containingAccessibilityText: "publish the task branch").waitForExistence(timeout: 5), app.debugDescription)
        alertSheet.buttons["OK"].click()
        let current = try XCTUnwrap(taskRecord(id: taskID))
        let record = try XCTUnwrap((current["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertNil(record["pullRequestNumber"])
        XCTAssertNil(record["pullRequestURL"])
        XCTAssertEqual(record["mergeTarget"] as? String, "main")
        XCTAssertEqual(current["status"] as? String, "Done")
    }

    // case-contract: test_done_archive_displays_existing_pull_request_link | A Done task's real SwiftData record retains a linked PR number and URL across fresh CLI/XPC reads so the archive renders the PR link with distinct hover emphasis and useful help; an active repository-backed task card renders a saved PR link with the same hover indication.
    func test_done_archive_displays_existing_pull_request_link() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI(["task", "create", "--title", "Archived linked PR UI", "--repo", fixture.primary.path])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Archived linked PR UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Archived linked PR UI")
        element("back-to-board-button").click()
        moveTaskToDone(taskID: taskID)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done")

        let activeCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Active linked PR UI", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any])
        let activeTaskID = try XCTUnwrap(activeCreated["id"] as? String)
        openTask(named: "Active linked PR UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Active linked PR UI")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "Review")

        app.terminate()
        XCTAssertTrue(waitUntil({ app.state == .notRunning }, timeout: 10), "The app must close its SwiftData container before seeding the isolated store.")
        let prURL = "https://github.com/stationai-test/fixture/pull/123"
        let activePRURL = "https://github.com/stationai-test/fixture/pull/456"
        try seedTaskPullRequest(taskID: taskID, number: 123, url: prURL)
        try seedTaskPullRequest(taskID: activeTaskID, number: 456, url: activePRURL)
        let persisted = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(persisted["status"] as? String, "Done")
        let record = try XCTUnwrap((persisted["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["pullRequestNumber"] as? Int, 123)
        XCTAssertEqual(record["pullRequestURL"] as? String, prURL)

        launchApp(defaultParent: fixture.parent.path)
        let activePRLink = app.links["task-pr-link-\(activeTaskID)-456"]
        XCTAssertTrue(activePRLink.waitForExistence(timeout: 10), "The active task card should show its saved PR number as a link.")
        assertHoverEmphasis(for: activePRLink)
        assertHelpTag(for: activePRLink, equals: "Open pull request #456 in your browser")
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitForExistence(timeout: 10))
        let prLink = app.links["done-archive-pr-link-\(taskID)-123"]
        XCTAssertTrue(prLink.waitForExistence(timeout: 10), "The Done archive should show the saved PR number as a link.")
        assertHoverEmphasis(for: prLink)
        assertHelpTag(for: prLink, equals: "Open pull request #123 in your browser")
        attachScreenshot(named: "Done archive shows the linked pull request")
    }

    // case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    func test_task_lifecycle_rollout_clears_records_and_clean_worktrees() throws {
        let clean = try runCLI(["task", "create", "--title", "Rollout clean", "--repo", fixture.primary.path])
        let dirty = try runCLI(["task", "create", "--title", "Rollout dirty", "--repo", fixture.secondary.path])
        let cleanResult = try XCTUnwrap(clean["result"] as? [String: Any])
        let dirtyResult = try XCTUnwrap(dirty["result"] as? [String: Any])
        let cleanRecord = try XCTUnwrap((cleanResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let dirtyRecord = try XCTUnwrap((dirtyResult["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        let dirtyPath = try XCTUnwrap(dirtyRecord["worktreePath"] as? String)
        let cleanBranch = try XCTUnwrap(cleanRecord["branch"] as? String)
        let dirtyBranch = try XCTUnwrap(dirtyRecord["branch"] as? String)
        let retainedFile = URL(fileURLWithPath: dirtyPath).appendingPathComponent("stationai-secondary.txt")
        try "Secondary baseline.\nKeep this worktree.\n".write(to: retainedFile, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("task-lifecycle-v2-reset"))

        launchApp(defaultParent: fixture.parent.path)
        XCTAssertEqual(element("task-count").value as? String, "0")
        let resetNotice = element("task-lifecycle-reset-notice")
        let resetDetails = element("task-lifecycle-reset-details")
        XCTAssertTrue(resetNotice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element("task-lifecycle-reset-title").exists)
        XCTAssertTrue(accessibleLabelOrValue(of: resetDetails).contains(dirtyPath), app.debugDescription)
        element("dismiss-task-lifecycle-reset-notice").click()
        XCTAssertNil(try taskRecord(named: "Rollout clean"))
        XCTAssertNil(try taskRecord(named: "Rollout dirty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertEqual(try String(contentsOf: retainedFile, encoding: .utf8), "Secondary baseline.\nKeep this worktree.\n")
        try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/\(cleanBranch)")
        try runGit(fixture.secondary, "show-ref", "--verify", "--quiet", "refs/heads/\(dirtyBranch)")
        attachScreenshot(named: "Lifecycle rollout clears tasks and reports a retained dirty worktree")
    }

    // case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status.
    func test_task_status_transitions_and_rejects_unknown_status() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Status transitions", roots: [fixture.primary.path])
        let columns = ["backlog", "in-progress", "review"]
        for column in columns { XCTAssertTrue(element("column-heading-\(column)").exists, "Missing \(column) board column.") }
        XCTAssertFalse(element("column-heading-done").exists, "Done tasks should live in the archive, not a board column.")
        XCTAssertFalse(element("column-heading-waiting-response").exists, "Waiting Response should be hidden when no tasks are waiting.")
        let inProgressColumn = element("column-in-progress")
        let reviewColumn = element("column-review")
        let boardViewport = element("board-columns-scroll-view")
        XCTAssertLessThan(inProgressColumn.frame.maxX, reviewColumn.frame.minX, "Review should remain a separate column after the stacked pair.")
        XCTAssertLessThanOrEqual(inProgressColumn.frame.maxY, boardViewport.frame.maxY, "In Progress should fit inside the visible board area.")
        XCTAssertLessThanOrEqual(reviewColumn.frame.maxY, boardViewport.frame.maxY, "Review should fit inside the visible board area.")
        XCTAssertFalse(element("column-heading-blocked").exists, "The blocked section should be hidden when no tasks are blocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
        XCTAssertFalse(element("column-heading-ready").exists)
        assertTaskVisible("Status transitions", inColumn: "Backlog")

        let statusTaskID = try taskID(named: "Status transitions")
        assertCLIError(try runCLI(["task", "move", statusTaskID, "Unknown"], expectedStatus: 2), code: "invalid_argument")
        for status in ["In Progress", "Blocked", "Waiting Response", "Review", "Done", "Backlog"] {
            assertCLIError(try runCLI(["task", "move", statusTaskID, status], expectedStatus: 2), code: "invalid_argument")
        }
        XCTAssertEqual(try taskRecord(named: "Status transitions")?["status"] as? String, "Backlog")
        assertTaskVisible("Status transitions", inColumn: "Backlog")

        let blockedTask = try runCLI(["task", "create", "--title", "Blocked layout", "--root", fixture.secondary.path])
        let blockedTaskID = try XCTUnwrap((blockedTask["result"] as? [String: Any])?["id"] as? String)
        let emptyFixture = try makeCodexFixture(emptyQuestions: true)
        assertCLIError(
            try runCLI(
                ["conversation", "send", blockedTaskID, "--message", "Please ask your questions."],
                expectedStatus: 1,
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": emptyFixture.path]
            ),
            code: "operation_failed"
        )
        XCTAssertEqual(try taskRecord(id: blockedTaskID)?["status"] as? String, "Blocked")

        try createTaskFixture(title: "In Progress layout", roots: [fixture.alternate.path])
        let activeTaskID = try taskID(named: "In Progress layout")
        let activeExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-progress-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: activeExecutable.path))
        let activeTurn = try startProgressFixtureTurn(taskID: activeTaskID, executable: activeExecutable)
        defer {
            if activeTurn.process.isRunning {
                try? "Release the active turn.\n".write(to: activeTurn.releaseMarker, atomically: true, encoding: .utf8)
                activeTurn.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeTurn.activeMarker)
            try? FileManager.default.removeItem(at: activeTurn.releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeTurn.activeMarker.path) }, timeout: 10))
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "In Progress")

        try createTaskFixture(title: "Waiting layout", roots: [fixture.secondary.path])
        let waitingTaskID = try taskID(named: "Waiting layout")
        openTask(named: "Waiting layout")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))

        assertTaskVisible("Blocked layout", inColumn: "Blocked")
        assertTaskVisible("Status transitions", inColumn: "Backlog")
        assertTaskVisible("Waiting layout", inColumn: "Waiting Response")
        assertTaskVisible("In Progress layout", inColumn: "In Progress")
        XCTAssertTrue(element("column-heading-blocked").exists)
        XCTAssertTrue(element("column-heading-waiting-response").exists)
        XCTAssertTrue(element("blocked-waiting-indicator").exists)
        let blockedColumn = element("column-blocked")
        let backlogColumn = element("column-backlog")
        let waitingResponseColumn = element("column-waiting-response")
        XCTAssertLessThan(blockedColumn.frame.maxY, backlogColumn.frame.minY, "Blocked should remain stacked above Backlog.")
        XCTAssertLessThan(waitingResponseColumn.frame.maxY, inProgressColumn.frame.minY, "Waiting Response should remain stacked above In Progress.")
        for topColumn in [blockedColumn, waitingResponseColumn] {
            XCTAssertGreaterThanOrEqual(topColumn.frame.minY, boardViewport.frame.minY)
        }
        for bottomColumn in [backlogColumn, inProgressColumn, reviewColumn] {
            XCTAssertLessThanOrEqual(bottomColumn.frame.maxY, boardViewport.frame.maxY)
        }
        XCTAssertLessThan(inProgressColumn.frame.maxX, reviewColumn.frame.minX, "Review should remain a separate column after the stacked pair.")
        XCTAssertFalse(element("column-heading-done").exists, "Done tasks should remain outside the board columns.")
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "In Progress")
        attachScreenshot(named: "Blocked and Waiting Response stacks fit with their active columns and Review")

        openTask(named: "Waiting layout")
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 5))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Review")

        try "Release the active turn.\n".write(to: activeTurn.releaseMarker, atomically: true, encoding: .utf8)
        activeTurn.process.waitUntilExit()
        let activeOutput = String(data: activeTurn.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let activeError = String(data: activeTurn.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(activeTurn.process.terminationStatus, 0, "The In Progress fixture turn should complete: \(activeOutput) \(activeError)")
        let activeResponseLine = try XCTUnwrap(activeOutput.split(whereSeparator: \.isNewline).last)
        let activeResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(activeResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(activeResponse["ok"] as? Bool == true)
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "Review")

        for index in 1...12 {
            try createTaskFixture(title: "Backlog scroll \(index)", roots: [fixture.primary.path])
        }
        let lowestTask = app.buttons["Backlog scroll 1"]
        XCTAssertTrue(lowestTask.waitForExistence(timeout: 10))
        XCTAssertFalse(lowestTask.isHittable, "The final backlog task should begin below the board viewport.")
        boardViewport.scroll(byDeltaX: 0, deltaY: -1200)
        XCTAssertTrue(waitUntil({ lowestTask.isHittable }, timeout: 5), "Vertical board scrolling should make lower backlog tasks reachable.")
    }

    // case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, clears explicitly and at turn completion, and the board card shows the built-in icon, label, and detail without changing lifecycle status; each new task thread receives hidden CLI usage instructions that persist with the thread.
    func test_task_progress_reports_publish_persist_and_clear() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Progress reports", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Progress reports")
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-progress-hold-release")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        codexFixtureExecutable = executable.path
        let activeMarker = URL(fileURLWithPath: executable.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: executable.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["conversation", "send", taskID, "--message", "Work on this task."]
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        environment["STATIONAI_E2E_CODEX_EXECUTABLE"] = executable.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        defer {
            if process.isRunning {
                try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The Codex fixture should hold the conversation turn open.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")

        let built = try runCLI(["task", "progress", "publish", taskID, "--type", "building", "--detail", "Compiling the app"])
        XCTAssertEqual((built["result"] as? [String: Any])?["progressLabel"] as? String, "Building")
        let reportID = "task-progress-report-\(taskID.uppercased())"
        let report = element(reportID)
        let icon = element("task-progress-icon-\(taskID.uppercased())")
        XCTAssertTrue(waitUntil({
            report.exists && report.label.contains("Building") && report.label.contains("Compiling the app")
        }, timeout: 10), "The board card should expose the Building label and detail.")
        XCTAssertTrue(waitUntil({ icon.exists && icon.label == "hammer" }, timeout: 10), "The Building SF Symbol should be exposed as a visible, accessible image.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "Publishing progress must not change lifecycle state.")
        XCTAssertEqual(try taskRecord(id: taskID)?["progressDetail"] as? String, "Compiling the app", "A fresh CLI/XPC connection should read the persisted report.")

        let custom = try runCLI(["task", "progress", "custom", taskID, "--label", "Checking migration", "--detail", "Reading the stored task data"])
        let customRecord = try XCTUnwrap(custom["result"] as? [String: Any])
        XCTAssertNil(customRecord["progressType"] as? String)
        XCTAssertEqual(customRecord["progressLabel"] as? String, "Checking migration")
        XCTAssertTrue(waitUntil({
            report.exists && report.label.contains("Checking migration") && report.label.contains("Reading the stored task data")
        }, timeout: 10), "The task card should update to a custom report with its detail and generic icon.")
        XCTAssertTrue(waitUntil({ icon.exists && icon.label == "sparkle" }, timeout: 10), "The custom report should expose its generic SF Symbol as a visible, accessible image.")
        assertCLIError(try runCLI(["task", "progress", "publish", taskID, "--type", "unknown"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["task", "progress", "custom", taskID, "--label", " "], expectedStatus: 2), code: "invalid_argument")

        let cleared = try runCLI(["task", "progress", "clear", taskID])
        XCTAssertNil((cleared["result"] as? [String: Any])?["progressLabel"])
        XCTAssertTrue(waitForDisappearance(report), "Clearing a report should remove its secondary row from the card.")
        _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing"])
        try "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "The fixture conversation should finish successfully: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        XCTAssertTrue(response["ok"] as? Bool == true)

        let resumedProcess = Process()
        resumedProcess.executableURL = cliURL
        resumedProcess.arguments = ["conversation", "send", taskID, "--message", "Continue on this task."]
        resumedProcess.environment = environment
        let resumedStdout = Pipe()
        let resumedStderr = Pipe()
        resumedProcess.standardOutput = resumedStdout
        resumedProcess.standardError = resumedStderr
        try resumedProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The follow-up should resume the existing fixture thread.")
        try "Release the resumed turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        resumedProcess.waitUntilExit()
        let resumedOutput = String(data: resumedStdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let resumedError = String(data: resumedStderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(resumedProcess.terminationStatus, 0, "The resumed fixture conversation should finish successfully: \(resumedOutput) \(resumedError)")
        let resumedResponseLine = try XCTUnwrap(resumedOutput.split(whereSeparator: \.isNewline).last)
        let resumedResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resumedResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(resumedResponse["ok"] as? Bool == true)

        let finished = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(finished["status"] as? String, "Review")
        XCTAssertNil(finished["progressLabel"], "Turn completion should clear the last live report.")
        XCTAssertTrue(waitForDisappearance(report), "Turn completion should remove the progress row from the board card.")
        let turnData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let turn = try XCTUnwrap(try JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        let instructions = try XCTUnwrap(turn["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(instructions.contains(cliURL.path))
        XCTAssertTrue(instructions.contains("task progress publish"))
        XCTAssertTrue(instructions.contains("hidden from the conversation"))
        XCTAssertEqual(turn["threadStartCount"] as? Int, 1, "The follow-up should reuse the thread created with progress instructions.")
        XCTAssertGreaterThanOrEqual(turn["threadResumeCount"] as? Int ?? 0, 1)
        let turns = try XCTUnwrap(turn["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.allSatisfy { $0["developerInstructions"] is NSNull }, "Turns should retain the collaboration mode's built-in instructions.")
    }

    // case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; the task card removes the report while lifecycle states remain Blocked or Waiting Response, and answering the question resumes the task successfully.
    func test_task_progress_reports_clear_on_failed_turns_and_questions() throws {
        launchApp(defaultParent: fixture.parent.path)
        var heldTurns: [(Process, URL, URL)] = []
        defer {
            for (process, activeMarker, releaseMarker) in heldTurns {
                if process.isRunning {
                    try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
                    process.waitUntilExit()
                }
                try? FileManager.default.removeItem(at: activeMarker)
                try? FileManager.default.removeItem(at: releaseMarker)
            }
        }
        for (fixtureName, expectedReason) in [
            ("codex-fixture-progress-hold-release-failed", "failed"),
            ("codex-fixture-progress-hold-release-interrupted", "interrupted"),
        ] {
            let title = "Progress \(expectedReason)"
            try createTaskFixture(title: title, roots: [fixture.primary.path])
            let taskID = try taskID(named: title)
            let executable = WorkspaceFixture.root.appendingPathComponent(fixtureName)
            let turn = try startProgressFixtureTurn(taskID: taskID, executable: executable)
            heldTurns.append((turn.process, turn.activeMarker, turn.releaseMarker))
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: turn.activeMarker.path) }, timeout: 10))
            let report = element("task-progress-report-\(taskID.uppercased())")
            _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing", "--detail", "Waiting for the result"])
            XCTAssertTrue(waitUntil({ report.exists && report.label.contains("Testing") }, timeout: 10), "The active task card should show progress before a failed turn.")
            XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")

            try "Release the active turn.\n".write(to: turn.releaseMarker, atomically: true, encoding: .utf8)
            turn.process.waitUntilExit()
            let output = String(data: turn.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let finalLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last)
            let finalResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(finalLine.utf8)) as? [String: Any])
            XCTAssertFalse(finalResponse["ok"] as? Bool ?? true, "The fixture turn should end as \(expectedReason).")
            let stopped = try XCTUnwrap(taskRecord(id: taskID))
            XCTAssertEqual(stopped["status"] as? String, "Blocked")
            XCTAssertNil(stopped["progressLabel"] as? String)
            XCTAssertTrue(waitForDisappearance(report), "A failed or interrupted turn should remove its progress row from the card.")
        }

        let questionFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-progress-question")
        codexFixtureExecutable = questionFixture.path
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = questionFixture.path
        relaunchApp()
        try createTaskFixture(title: "Progress question", roots: [fixture.primary.path])
        openTask(named: "Progress question")
        let questionTaskID = try taskID(named: "Progress question")
        let activeMarker = URL(fileURLWithPath: questionFixture.path + ".turn-active")
        let releaseMarker = URL(fileURLWithPath: questionFixture.path + ".turn-release")
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
        defer {
            try? "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: activeMarker)
            try? FileManager.default.removeItem(at: releaseMarker)
        }
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The question fixture should hold the turn before asking for input.")
        let waitingReport = try runCLI(["task", "progress", "publish", questionTaskID, "--type", "reviewing", "--detail", "Preparing a question"])
        XCTAssertEqual((waitingReport["result"] as? [String: Any])?["progressLabel"] as? String, "Reviewing")
        try "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: questionTaskID)?["status"] as? String, "Waiting Response")
        XCTAssertNil(try taskRecord(id: questionTaskID)?["progressLabel"] as? String, "Progress should clear as soon as Codex requests user input.")
        element("back-to-board-button").click()
        let waitingCard = element("task-card-\(questionTaskID.uppercased())")
        XCTAssertTrue(waitingCard.waitForExistence(timeout: 8))
        let waitingReportRow = element("task-progress-report-\(questionTaskID.uppercased())")
        XCTAssertTrue(waitForDisappearance(waitingReportRow), "The Waiting Response card should not retain the agent's progress row.")
        openTask(named: "Progress question")
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 5), "Reopening should preserve the pending question.")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        let completionDeadline = Date().addingTimeInterval(10)
        var completedStatus: String?
        while Date() < completionDeadline {
            completedStatus = try taskRecord(id: questionTaskID)?["status"] as? String
            if completedStatus == "Review" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Review", "Answering the question should resume and finish the task.")
        XCTAssertNil(try taskRecord(id: questionTaskID)?["progressLabel"] as? String)
        try? FileManager.default.removeItem(at: activeMarker)
        try? FileManager.default.removeItem(at: releaseMarker)
    }

    // case-contract: test_task_rename_persists_and_rejects_blank_title | A rename waits for the real per-task operation lock, then persists across fresh CLI/XPC reads; rejecting a blank rename preserves the last valid title.
    func test_task_rename_persists_and_rejects_blank_title() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Before rename", roots: [fixture.primary.path])
        let taskID = try taskID(named: "Before rename")
        let operationLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        let card = app.buttons.matching(NSPredicate(format: "label == %@", "Before rename")).firstMatch
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
        XCTAssertTrue(card.waitForExistence(timeout: 3), "The persisted title should remain unchanged while the task-operation lock is held.")
        try operationLock.release()
        XCTAssertTrue(app.buttons["After rename"].waitForExistence(timeout: 10))

        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        assertCLIError(
            try runCLI(["task", "rename", taskID, "--title", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        XCTAssertEqual(try taskRecord(named: "After rename")?["title"] as? String, "After rename")
        attachScreenshot(named: "Renamed task remains unchanged after rejected blank rename")
    }

    // case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, rejects an empty list, and waits for an active conversation turn; a stale Git-folder validation is rejected after a newer folder edit, and the newer roots remain saved.
    func test_task_roots_set_get_order_deduplication_and_validation() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Edit roots", "--repo", fixture.primary.path])
        openTask(named: "Edit roots")
        element("edit-workspace-roots-button").click()
        XCTAssertTrue(element("save-workspace-roots-button").waitForExistence(timeout: 5))

        element("repository-suggestion-secondary").click()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "secondary")).count, 1)
        XCTAssertFalse(element("repository-suggestion-secondary").exists, "A selected repository must leave the suggestion list.")
        let current = try XCTUnwrap(taskRecord(named: "Edit roots")?["repositoryWorktrees"] as? [[String: Any]])
        _ = try XCTUnwrap(current.first?["worktreePath"] as? String)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "primary ·")).firstMatch.click()
        let secondaryPath = fixture.secondary.lastPathComponent
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondaryPath)).firstMatch.click()
        let saveButton = element("save-workspace-roots-button")
        XCTAssertFalse(saveButton.isEnabled, "The editor must require at least one folder.")
        element("repository-suggestion-secondary").click()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("repository-suggestion-primary").click()
        let taskID = try taskID(named: "Edit roots")
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        saveButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            try taskRecord(id: taskID)?["workspaceRoots"] as? [String],
            [fixture.primary.path],
            "Workspace roots should remain unchanged while a conversation turn holds its reservation."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        XCTAssertTrue(waitUntil({
            guard let current = try? self.taskRecord(id: taskID),
                  let roots = current["workspaceRoots"] as? [String] else { return false }
            return roots != [self.fixture.primary.path]
        }, timeout: 10), "The saved workspace roots should update after the conversation turn releases its reservation.")
        let taskAfterEdit = try XCTUnwrap(taskRecord(named: "Edit roots"))
        let expectedRoots = try XCTUnwrap(taskAfterEdit["workspaceRoots"] as? [String])
        assertOrderedRoots(expectedRoots)

        let duplicateRoots = try runCLI([
            "task", "roots", "set", taskID,
            "--root", fixture.secondary.path,
            "--root", fixture.secondary.path,
            "--root", fixture.custom.path,
            "--root", fixture.primary.path
        ])
        let rootsAfterCliEdit = try XCTUnwrap((duplicateRoots["result"] as? [String: Any])?["workspaceRoots"] as? [String])
        let result = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(result?["roots"] as? [String], rootsAfterCliEdit)
        assertCLIError(try runCLI(["task", "roots", "set", taskID], expectedStatus: 2), code: "invalid_argument")
        let unchanged = try runCLI(["task", "roots", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(unchanged?["roots"] as? [String], rootsAfterCliEdit)

        let concurrentTitle = "Concurrent root edit"
        let concurrent = try runCLI([
            "task", "create", "--title", concurrentTitle,
            "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let concurrentID = try XCTUnwrap(concurrent?["id"] as? String)
        relaunchApp()
        let barrier = try GitConfigReadBarrier(repositoryURL: fixture.secondary)
        var staleProcess: RunningCLIProcess?
        var barrierReleased = false
        var continueStaleProcess = false
        defer {
            if !barrierReleased { try? barrier.release() }
            if !continueStaleProcess, let process = staleProcess?.process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        staleProcess = try startCLIProcess(["task", "roots", "set", concurrentID, "--root", fixture.secondary.path])
        try barrier.waitForReader()

        openTask(named: concurrentTitle)
        element("edit-workspace-roots-button").click()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "primary ·")).firstMatch.click()
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("save-workspace-roots-button").click()
        XCTAssertTrue(waitUntil({
            do {
                guard let current = try self.taskRecord(id: concurrentID) else { return false }
                return current["workspaceRoots"] as? [String] == [self.fixture.custom.path]
                    && current["contextFolders"] as? [String] == [self.fixture.custom.path]
                    && (current["repositoryWorktrees"] as? [Any])?.isEmpty == true
            } catch { return false }
        }, timeout: 10), "The newer UI folder edit should persist before the stale validation is released.")

        try barrier.release()
        barrierReleased = true
        continueStaleProcess = true
        let stale = try finishCLIProcess(try XCTUnwrap(staleProcess), expectedStatus: 1)
        XCTAssertEqual((stale["error"] as? [String: Any])?["code"] as? String, "invalid_transition")
        let fresh = try XCTUnwrap(taskRecord(id: concurrentID))
        XCTAssertEqual(fresh["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(fresh["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual((fresh["repositoryWorktrees"] as? [Any])?.count, 0)
        attachScreenshot(named: "Edited ordered folders in task conversation")
    }

    // case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; adding it waits for an active conversation turn, then persists a pending auto branch with labeled branch, merge-from, and merge-to values, and no worktree exists before the first send.
    func test_conversation_repository_picker_adds_repository_worktree() throws {
        launchApp(defaultParent: fixture.parent.path)
        let created = try runCLI(["task", "create", "--title", "Header repository picker", "--root", fixture.primary.path])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: "Header repository picker")
        element("add-conversation-repository-button").click()
        let search = element("conversation-repository-search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("suggested-parent")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversation-repository-suggestion-changes").exists)
        XCTAssertTrue(element("conversation-repository-suggestion-secondary").exists)
        let suggestionResult = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        let suggestionPaths = try XCTUnwrap(suggestionResult?["repositories"] as? [String])
        let primarySuggestionIndex = try XCTUnwrap(suggestionPaths.firstIndex(of: fixture.primary.path))
        XCTAssertGreaterThan(primarySuggestionIndex, 0, "The primary repository should follow another suggestion so both arrow directions can be tested.")
        for _ in 0..<primarySuggestionIndex {
            search.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        }
        search.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        search.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        let suggestion = element("conversation-repository-suggestion-primary")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        search.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            (try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.count,
            0,
            "The selected repository should not be attached until the conversation turn releases its reservation."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        let title = element("task-view-title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(badge.frame.minX, title.frame.maxX, "Repository badges should appear to the right of the task title.")
        XCTAssertLessThan(abs(badge.frame.midY - title.frame.midY), 8, "Repository badges should share the title row.")
        let record = try XCTUnwrap(taskRecord(named: "Header repository picker"))
        let repositories = try XCTUnwrap(record["repositoryWorktrees"] as? [[String: Any]])
        let primary = try XCTUnwrap(repositories.first { ($0["repositoryPath"] as? String) == fixture.primary.path })
        let worktreePath = try XCTUnwrap(primary["worktreePath"] as? String)
        XCTAssertEqual(worktreePath, fixture.primary.path)
        XCTAssertEqual(primary["isPending"] as? Bool, true)
        XCTAssertEqual(primary["branch"] as? String, "auto")
        XCTAssertEqual(record["workspaceRoots"] as? [String], [fixture.primary.path])
        XCTAssertEqual(record["contextFolders"] as? [String], [])
        let branch = try XCTUnwrap(primary["branch"] as? String)
        let mergeFrom = try XCTUnwrap(primary["branchFrom"] as? String)
        let mergeTo = try XCTUnwrap(primary["mergeTarget"] as? String)
        badge.click()
        let branchValue = element("conversation-repository-branch-value")
        let branchFromValue = element("conversation-repository-branch-from-value")
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(branchValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(branchFromValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mergeTargetValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchValue), branch, app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchFromValue), mergeFrom, app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), mergeTo, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Branch name"].exists)
        XCTAssertTrue(app.staticTexts["Branch from"].exists)
        XCTAssertTrue(app.staticTexts["Merge to"].exists)
        XCTAssertTrue(element("conversation-repository-branch-edit").exists)
        XCTAssertTrue(element("conversation-repository-branch-from-edit").exists)
        XCTAssertTrue(element("conversation-repository-merge-target-edit").exists)
    }

    // case-contract: test_task_repository_settings_validate_persist_and_lock_after_start | Pending repository branch, merge-from, and merge-to settings wait for an active conversation turn, then persist across fresh CLI/XPC reads; invalid settings leave prior values intact, and settings are locked after worktree creation.
    func test_task_repository_settings_validate_persist_and_lock_after_start() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let title = "Repository settings through UI"
        let created = try runCLI([
            "task", "create", "--title", title,
            "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: title)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))

        let initial = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        let initialBranch = try XCTUnwrap(initial["branch"] as? String)
        badge.click()
        element("conversation-repository-branch-edit").click()
        let branchField = element("conversation-repository-branch")
        replaceText(branchField, with: "invalid branch")
        element("save-conversation-repository-button").click()
        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10), "Invalid branch settings should be shown in the conversation.")
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String, initialBranch)

        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        replaceText(branchField, with: "conversation-edited")
        element("save-conversation-repository-button").click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["branch"] as? String,
            initialBranch,
            "Repository settings should remain unchanged while a conversation turn holds its reservation."
        )
        try conversationReservation.release()
        conversationReservationReleased = true
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branch", expected: "conversation-edited"))

        badge.click()
        element("conversation-repository-branch-from-edit").click()
        let branchFromField = element("conversation-repository-branch-from")
        replaceText(branchFromField, with: "branch-source")
        element("save-conversation-repository-button").click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "branch-source"))

        badge.click()
        element("conversation-repository-merge-target-edit").click()
        let mergeTargetField = element("conversation-repository-merge-target")
        replaceText(mergeTargetField, with: "branch-source")
        element("save-conversation-repository-button").click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "branch-source"))
        badge.click()
        element("conversation-repository-merge-target-edit").click()
        replaceText(mergeTargetField, with: "missing-local-branch")
        element("save-conversation-repository-button").click()
        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10), "An invalid merge target should be shown in the conversation.")
        XCTAssertEqual(
            try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["mergeTarget"] as? String,
            "branch-source",
            "Rejecting an invalid merge target must preserve the saved value."
        )
        replaceText(mergeTargetField, with: "branch-source")
        element("save-conversation-repository-button").click()
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "branch-source"))
        badge.click()
        let branchValue = element("conversation-repository-branch-value")
        let branchFromValue = element("conversation-repository-branch-from-value")
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(branchValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(branchFromValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mergeTargetValue.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchValue), "conversation-edited", app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: branchFromValue), "branch-source", app.debugDescription)
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "branch-source", app.debugDescription)
        XCTAssertEqual(try repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path)?["isPending"] as? Bool, true)

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
        badge.click()
        XCTAssertTrue(element("conversation-repository-settings-locked").waitForExistence(timeout: 5))
        XCTAssertFalse(element("conversation-repository-branch-edit").exists)
        XCTAssertFalse(element("save-conversation-repository-button").exists)
        assertCLIError(
            try runCLI([
                "task", "repository", "edit", taskID,
                "--repo", fixture.primary.path,
                "--branch", "changed-after-start",
                "--branch-from", "branch-source",
                "--merge-target", "branch-source",
            ], expectedStatus: 1),
            code: "invalid_transition"
        )
        let final = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(final["branch"] as? String, "conversation-edited")
        XCTAssertEqual(final["branchFrom"] as? String, "branch-source")
        XCTAssertEqual(final["mergeTarget"] as? String, "branch-source")
        XCTAssertEqual(final["isPending"] as? Bool, false)
    }

    // case-contract: test_task_repository_edit_rejects_stale_validation_after_removal | If a pending repository is removed while its settings are being validated, the stale edit is rejected and the newer repository removal and context root remain saved.
    func test_task_repository_edit_rejects_stale_validation_after_removal() throws {
        launchApp(defaultParent: fixture.parent.path)
        let title = "Concurrent repository edit"
        let created = try runCLI([
            "task", "create", "--title", title,
            "--repo", fixture.primary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: title)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        badge.click()
        element("conversation-repository-branch-edit").click()
        replaceText(element("conversation-repository-branch"), with: "stale-ui-edit")

        let barrier = try GitConfigReadBarrier(repositoryURL: fixture.primary)
        element("save-conversation-repository-button").click()
        var barrierReleased = false
        defer {
            if !barrierReleased { try? barrier.release() }
        }
        try barrier.waitForReader()
        let removed = try runCLI(["task", "repository", "remove", taskID, "--repo", fixture.primary.path])
        let removedTask = try XCTUnwrap(removed["result"] as? [String: Any])
        XCTAssertEqual((removedTask["repositoryWorktrees"] as? [Any])?.count, 0)
        XCTAssertEqual(removedTask["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(removedTask["contextFolders"] as? [String], [fixture.custom.path])

        try barrier.release()
        barrierReleased = true
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "The stale repository edit should be reported in the conversation.")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("settings changed"), error.label)
        let fresh = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual((fresh["repositoryWorktrees"] as? [Any])?.count, 0)
        XCTAssertEqual(fresh["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(fresh["contextFolders"] as? [String], [fixture.custom.path])
        attachScreenshot(named: "Concurrent repository removal rejects a stale settings save")
    }

    // case-contract: test_task_repository_removal_preserves_state_on_dirty_worktree | Removing the only pending repository leaves the task with no workspace and preserves the source repository; removing a pending repository preserves other context folders; removing a clean managed worktree waits for an active conversation turn and then succeeds, while a dirty worktree rejects removal and preserves its task record and files.
    func test_task_repository_removal_preserves_state_on_dirty_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let soleTitle = "Sole repository removal through UI"
        let sole = try runCLI(["task", "create", "--title", soleTitle, "--repo", fixture.primary.path])["result"] as? [String: Any]
        let soleID = try XCTUnwrap(sole?["id"] as? String)
        openTask(named: soleTitle)
        element("conversation-repository-badge-primary").click()
        element("remove-conversation-repository-button").click()
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: soleID),
                  let records = result["repositoryWorktrees"] as? [Any] else { return false }
            return records.isEmpty
        }, timeout: 10), "Removing the only pending repository should leave the task without a workspace.")
        XCTAssertEqual(try taskRecord(id: soleID)?["workspaceRoots"] as? [String], [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.primary.path))

        element("back-to-board-button").click()
        let pendingTitle = "Pending repository removal through UI"
        let pending = try runCLI([
            "task", "create", "--title", pendingTitle,
            "--repo", fixture.primary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let pendingID = try XCTUnwrap(pending?["id"] as? String)
        openTask(named: pendingTitle)
        element("conversation-repository-badge-primary").click()
        element("remove-conversation-repository-button").click()
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: pendingID),
                  let records = result["repositoryWorktrees"] as? [[String: Any]] else { return false }
            return records.isEmpty
        }, timeout: 10), "Removing a pending repository should update the persisted task.")
        let pendingAfterRemoval = try XCTUnwrap(taskRecord(id: pendingID))
        XCTAssertEqual(pendingAfterRemoval["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(pendingAfterRemoval["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.primary.path), "The source repository must remain on disk.")

        element("back-to-board-button").click()
        let activeTitle = "Started repository removal through UI"
        let active = try runCLI([
            "task", "create", "--title", activeTitle,
            "--repo", fixture.secondary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let activeID = try XCTUnwrap(active?["id"] as? String)
        openTask(named: activeTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: activeTitle)
        let activeRecord = try XCTUnwrap(repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path))
        let worktreePath = try XCTUnwrap(activeRecord["worktreePath"] as? String)
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let dirtyFile = worktreeURL.appendingPathComponent("repository-removal-dirty.txt")
        try Data("keep this worktree intact\n".utf8).write(to: dirtyFile)

        element("conversation-repository-badge-secondary").click()
        let removeButton = element("remove-conversation-repository-button")
        removeButton.click()
        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10), "Dirty worktree removal should report an error in the conversation.")
        XCTAssertTrue(element("codex-chat-error").label.contains("uncommitted changes"))
        XCTAssertEqual(try repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path)?["worktreePath"] as? String, worktreePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyFile.path))

        try FileManager.default.removeItem(at: dirtyFile)
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "The repository can be removed after its worktree is clean.")
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: activeID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        removeButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(
            try repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path)?["worktreePath"] as? String,
            worktreePath,
            "Repository removal should wait while a conversation turn holds its reservation."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))
        try conversationReservation.release()
        conversationReservationReleased = true
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: activeID),
                  let records = result["repositoryWorktrees"] as? [[String: Any]] else { return false }
            return records.isEmpty
        }, timeout: 10), "Removing a clean managed worktree should update the persisted task.")
        let activeAfterRemoval = try XCTUnwrap(taskRecord(id: activeID))
        XCTAssertEqual(activeAfterRemoval["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(activeAfterRemoval["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    // case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; confirmed deletion waits for an active conversation turn; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check derives and reports the confirmation requirement from saved task and worktree state without resuming the Codex thread; confirmed deletion removes the managed worktree.
    func test_task_delete_removes_task_and_later_lookup_is_not_found() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let pendingTitle = "Pending delete"
        _ = try runCLI(["task", "create", "--title", pendingTitle, "--repo", fixture.secondary.path])
        let pendingTask = try XCTUnwrap(taskRecord(named: pendingTitle))
        let pendingID = try XCTUnwrap(pendingTask["id"] as? String)
        let pendingRecord = try XCTUnwrap((pendingTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(pendingRecord["isPending"] as? Bool, true)
        XCTAssertEqual(pendingRecord["worktreePath"] as? String, fixture.secondary.path)
        let pendingCheck = try runCLI(["task", "delete-check", pendingID])
        XCTAssertEqual((pendingCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, false)
        deleteTaskFromContextMenu(pendingTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitForExistence(timeout: 5))
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: pendingID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        element("confirm-delete-task-button").click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try taskRecord(id: pendingID)?["id"] as? String, pendingID)
        try conversationReservation.release()
        conversationReservationReleased = true
        assertCLIError(try runCLI(["task", "get", pendingID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.secondary.path), "Deleting a pending task must preserve its source repository.")

        let diagnosticLog = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        let deleteEvents = try diagnosticLog.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let pendingDeleteEvent = try XCTUnwrap(deleteEvents.first {
            $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == pendingID
        }, "Deleting a task through the visible menu should leave a persistent diagnostic event.")
        XCTAssertEqual(pendingDeleteEvent["taskStatus"] as? String, "Backlog")
        XCTAssertNotNil(pendingDeleteEvent["processID"] as? String)
        XCTAssertNotNil(pendingDeleteEvent["storePath"] as? String)

        let cleanTitle = "Clean delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", cleanTitle, "--repo", fixture.primary.path])
        openTask(named: cleanTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: cleanTitle)
        element("back-to-board-button").click()
        let cleanTask = try XCTUnwrap(taskRecord(named: cleanTitle))
        let cleanID = try XCTUnwrap(cleanTask["id"] as? String)
        let cleanRecord = try XCTUnwrap((cleanTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        XCTAssertEqual(cleanRecord["isPending"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertEqual(try runGitOutput(URL(fileURLWithPath: cleanPath), "status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines), "")
        let cleanThreadID = try XCTUnwrap(cleanTask["codexThreadID"] as? String)
        let resumeEventsBeforeDeleteCheck = try diagnosticEvents().filter {
            $0["event"] as? String == "codex.thread.resume_started" && $0["threadID"] as? String == cleanThreadID
        }.count
        let cleanCheck = try runCLI(["task", "delete-check", cleanID])
        XCTAssertEqual((cleanCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, true)
        let resumeEventsAfterDeleteCheck = try diagnosticEvents().filter {
            $0["event"] as? String == "codex.thread.resume_started" && $0["threadID"] as? String == cleanThreadID
        }.count
        XCTAssertEqual(resumeEventsAfterDeleteCheck, resumeEventsBeforeDeleteCheck, "Delete-check must not resume a conversation thread already owned by the app.")
        deleteTaskFromContextMenu(cleanTitle)
        let cleanConfirmation = element("confirm-delete-task-button")
        XCTAssertTrue(cleanConfirmation.waitForExistence(timeout: 5))
        cleanConfirmation.click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == cleanID
            }) ?? false
        }, timeout: 20), "The app should finish the confirmed delete and record success before the worktree check.")
        assertCLIError(try runCLI(["task", "get", cleanID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: cleanPath) }, timeout: 10), "Deleting a clean started task must remove its managed worktree before the task record disappears.")

        let dirtyTitle = "Dirty delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", dirtyTitle, "--repo", fixture.primary.path])
        let dirtyID = try taskID(named: dirtyTitle)
        openTask(named: dirtyTitle)
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("Prepare a task for deletion.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(id: dirtyID)?["status"] as? String, "Review")
        element("back-to-board-button").click()
        let dirtyTask = try XCTUnwrap(taskRecord(id: dirtyID))
        let dirtyRecord = try XCTUnwrap((dirtyTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let dirtyPath = try XCTUnwrap(dirtyRecord["worktreePath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath))
        try "unsaved work\n".write(to: URL(fileURLWithPath: dirtyPath).appendingPathComponent("trash-test.txt"), atomically: true, encoding: .utf8)
        let dirtyCheck = try runCLI(["task", "delete-check", dirtyID])
        XCTAssertEqual((dirtyCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, true)

        deleteTaskFromContextMenu(dirtyTitle)
        let cancel = element("cancel-delete-task-button")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Dirty work dropped on trash must require confirmation.")
        cancel.click()
        XCTAssertTrue(app.buttons[dirtyTitle].exists, "Canceling deletion must preserve the task.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath), "Canceling deletion must preserve the worktree.")

        deleteTaskFromContextMenu(dirtyTitle)
        let confirmation = element("confirm-delete-task-button")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == dirtyID
            }) ?? false
        }, timeout: 20), "The app should finish the confirmed delete and record success before the worktree check.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyPath), "Confirmed deletion must remove the dirty managed worktree.")
        assertCLIError(try runCLI(["task", "get", dirtyID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Deleted task removed from the board")
    }

    // case-contract: test_task_delete_reports_real_worktree_failure_and_allows_retry | A real worktree-removal failure records the task title and task, thread, process, phase, and underlying error details, including bounded NSError user-info keys and values, without recording conversation text; the failed task and worktree remain available and deletion succeeds after the repository is restored.
    func test_task_delete_reports_real_worktree_failure_and_allows_retry() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let brokenRepository = dataDirectory.appendingPathComponent("delete-failure-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRepository, withIntermediateDirectories: true)
        try runGit(brokenRepository, "init", "--initial-branch=main")
        try runGit(brokenRepository, "config", "user.name", "StationAI UI Test")
        try runGit(brokenRepository, "config", "user.email", "stationai-ui-test@example.invalid")
        try "owned diagnostic fixture\n".write(
            to: brokenRepository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try runGit(brokenRepository, "add", "README.md")
        try runGit(brokenRepository, "commit", "-m", "Baseline")
        let failureTitle = "PRIVATE_DELETE_TITLE_\(String(UUID().uuidString.prefix(8)))"
        let failurePrompt = "PRIVATE_CONVERSATION_TEXT_\(String(UUID().uuidString.prefix(8)))"
        _ = try runCLI(["task", "create", "--title", failureTitle, "--repo", brokenRepository.path])
        openTask(named: failureTitle)
        element("message-composer").click()
        element("message-composer").typeText(failurePrompt)
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        element("back-to-board-button").click()
        let failureTask = try XCTUnwrap(taskRecord(named: failureTitle))
        let failureID = try XCTUnwrap(failureTask["id"] as? String)
        let failureRecord = try XCTUnwrap((failureTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let failureWorktree = try XCTUnwrap(failureRecord["worktreePath"] as? String)
        let movedRepository = dataDirectory.appendingPathComponent("delete-failure-repository-restored-after-error", isDirectory: true)
        try FileManager.default.moveItem(at: brokenRepository, to: movedRepository)
        deleteTaskFromContextMenu(failureTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitForExistence(timeout: 5))
        element("confirm-delete-task-button").click()
        let saveErrorAlert = app.sheets.firstMatch
        XCTAssertTrue(saveErrorAlert.waitForExistence(timeout: 10), "A worktree-removal failure should be visible to the user.")
        XCTAssertTrue(element(containingAccessibilityText: "Diagnostics.jsonl").waitForExistence(timeout: 5), app.debugDescription)
        let failureLog = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        let failureEvents = try failureLog.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failedDelete = try XCTUnwrap(failureEvents.first {
            $0["event"] as? String == "task.delete.failed" && $0["taskID"] as? String == failureID
        })
        XCTAssertEqual(failedDelete["phase"] as? String, "worktree-removal")
        XCTAssertEqual(failedDelete["taskStatus"] as? String, "Review")
        XCTAssertTrue((failedDelete["threadID"] as? String)?.isEmpty == false)
        XCTAssertNotNil(failedDelete["clientPID"] as? String)
        XCTAssertNotNil(failedDelete["codexPID"] as? String)
        XCTAssertNotNil(failedDelete["error0Domain"] as? String)
        XCTAssertNotNil(failedDelete["error0Code"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfoKeys"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfoKeyCount"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfo"] as? String)
        XCTAssertTrue(failureLog.contains(failureTitle), "Diagnostics should record the task title to help identify the affected task.")
        XCTAssertFalse(failureLog.contains(failurePrompt), "Diagnostics must not record conversation text.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureWorktree), "A failed deletion must preserve the worktree for retry.")
        XCTAssertEqual(try taskRecord(id: failureID)?["id"] as? String, failureID, "A failed deletion must preserve the task for retry.")
        saveErrorAlert.buttons["OK"].click()
        try FileManager.default.moveItem(at: movedRepository, to: brokenRepository)
        deleteTaskFromContextMenu(failureTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitForExistence(timeout: 5))
        element("confirm-delete-task-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == failureID
            }) ?? false
        }, timeout: 20), "Restoring the repository should allow the retry to complete and record success.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureWorktree), "Restoring the repository should allow deletion to be retried.")
        assertCLIError(try runCLI(["task", "get", failureID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Failed task deletion can be retried after repository recovery")
    }

    // case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. In the UI, the conversation picker keeps a Change parent affordance visible after a valid parent is selected, and choosing another folder refreshes suggestions and persists the new parent. Dark and Light appearance choices persist and log successful writes, an external CLI appearance write updates the open Settings picker, and Dark renders the workspace canvas as #1E1E1E in the VS Code Dark+ palette.
    func test_default_parent_settings_read_write_clear_and_validation() throws {
        launchApp(defaultParent: nil)
        let initialSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(initialSettings?["defaultParentFolder"] as? String)
        openNewTaskConversation()
        XCTAssertEqual(try tasksFromBoardList().count, 1, "New Task should create its pending conversation before folder discovery.")
        element("choose-repository-suggestion-parent-button").click()
        let firstRunPanel = openFolderPanel
        XCTAssertTrue(firstRunPanel.waitForExistence(timeout: 10))
        firstRunPanel.buttons["Cancel"].click()
        XCTAssertTrue(element("conversation-repository-search").waitForExistence(timeout: 5), "Canceling folder selection should leave the direct-created task and picker open.")
        XCTAssertEqual(try tasksFromBoardList().count, 1)

        element("choose-repository-suggestion-parent-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitForExistence(timeout: 10), "Choosing a suggestion folder should populate the conversation picker.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["defaultParentFolder"] as? String, fixture.parent.path)
        let changeSuggestionParent = element("choose-repository-suggestion-parent-button")
        XCTAssertTrue(changeSuggestionParent.waitForExistence(timeout: 5), "The picker should keep a Change parent action available after a valid parent has been selected.")
        XCTAssertTrue(changeSuggestionParent.label.localizedCaseInsensitiveContains("Change"))
        changeSuggestionParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.alternateParent, confirmationButton: "Use This Folder")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitForExistence(timeout: 10), "Changing the parent should refresh the repository suggestions.")
        XCTAssertFalse(element("conversation-repository-suggestion-primary").exists, "Suggestions from the previous parent should be replaced.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["defaultParentFolder"] as? String, fixture.alternateParent.path)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try tasksFromBoardList().count, 0, "Backing out should discard the empty pending conversation.")

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let appearancePicker = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "appearance-picker").firstMatch
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 5), "Workspace Settings should expose the Dark and Light theme choices.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        try runCLI(["settings", "set-appearance", "light"])
        XCTAssertTrue(waitUntil({ appearancePicker.value as? String == "light" }, timeout: 5), "An external settings write should update the open appearance picker.")
        try runCLI(["settings", "set-appearance", "dark"])
        XCTAssertTrue(waitUntil({ appearancePicker.value as? String == "dark" }, timeout: 5), "A second external settings write should update the open appearance picker again.")
        appearancePicker.click()
        let lightChoice = preferencesWindow.menuItems["Light"]
        if lightChoice.waitForExistence(timeout: 2) {
            lightChoice.click()
        } else {
            preferencesWindow.buttons["Light"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "light")
        let lightAppearanceEvent = try diagnosticEvents().first {
            $0["event"] as? String == "settings.write.succeeded"
                && $0["setting"] as? String == "appearance"
                && $0["value"] as? String == "light"
        }
        XCTAssertNotNil(lightAppearanceEvent, "Changing the theme in Settings should log the successful appearance write.")
        appearancePicker.click()
        let darkChoice = preferencesWindow.menuItems["Dark"]
        if darkChoice.waitForExistence(timeout: 2) {
            darkChoice.click()
        } else {
            preferencesWindow.buttons["Dark"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        let darkAppearanceEvent = try diagnosticEvents().first {
            $0["event"] as? String == "settings.write.succeeded"
                && $0["setting"] as? String == "appearance"
                && $0["value"] as? String == "dark"
        }
        XCTAssertNotNil(darkAppearanceEvent, "Changing the theme back to Dark should log the successful appearance write.")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferencesWindow.exists }, timeout: 5), "Settings should close before checking the workspace canvas.")
        let workspaceCanvas = element("board-columns-scroll-view")
        XCTAssertTrue(workspaceCanvas.waitForExistence(timeout: 5), "The board workspace should be visible.")
        assertPixel(workspaceCanvas.screenshot().image, normalizedX: 0.02, normalizedY: 0.5, rgb: (30, 30, 30), accuracy: 12)
        app.typeKey(",", modifierFlags: .command)
        let reopenedPreferences = settingsWindow
        XCTAssertTrue(reopenedPreferences.waitForExistence(timeout: 10), "Workspace Settings did not reopen.")
        let chooseParent = reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "choose-default-parent-folder-button").firstMatch
        XCTAssertTrue(chooseParent.waitForExistence(timeout: 10))
        assertHelpTag(for: chooseParent, equals: "Choose parent folder")
        chooseParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        assertText("default-parent-folder-path", equals: fixture.parent.path)
        let saved = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(saved?["defaultParentFolder"] as? String, fixture.parent.path)

        assertCLIError(
            try runCLI(["settings", "set-parent", fixture.missing.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertText("default-parent-folder-path", equals: fixture.parent.path)
        reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch.click()
        let cleared = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(cleared?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        attachScreenshot(named: "Workspace settings can be changed and cleared")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !reopenedPreferences.exists }, timeout: 5), "Settings should close before the next UI case launches.")
        XCTAssertTrue(element("board-title").exists, "The main board should remain open when Settings closes.")
    }

    // case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | The CLI returns top-level Git repository suggestions while excluding nested repositories and symlink targets. The conversation picker shows those suggestions, filters by repository name or parent path, and reports no matches for non-repository folders.
    func test_repository_suggestions_skip_nested_repositories_and_symlinks() throws {
        launchApp(defaultParent: fixture.parent.path)
        let result = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        let expectedRepositories = [fixture.primary.path, fixture.secondary.path, fixture.alternate.path, fixture.changes.path].sorted()
        XCTAssertEqual(result?["repositories"] as? [String], expectedRepositories)

        openNewTaskConversation()
        let search = element("conversation-repository-search")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitForExistence(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-nested").exists, "Nested Git folders should not be suggested.")
        XCTAssertFalse(element("conversation-repository-suggestion-linked-outside").exists, "Symlink targets should not be suggested.")
        replaceText(search, with: "primary")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitForExistence(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-secondary").exists, "Search should filter suggestions by repository name.")
        replaceText(search, with: "linked-outside")
        XCTAssertTrue(app.staticTexts["No matching repositories."].waitForExistence(timeout: 5))
        replaceText(search, with: "group")
        XCTAssertTrue(element("conversation-repository-suggestion-secondary").waitForExistence(timeout: 5), "A path-only query should find a repository inside a matching parent folder.")
        XCTAssertFalse(element("conversation-repository-suggestion-primary").exists)
        replaceText(search, with: "changes")
        XCTAssertTrue(element("conversation-repository-suggestion-changes").exists)
        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "Repository suggestions exclude nested and symlinked folders")
    }

    // case-contract: test_new_task_remembers_last_selected_repositories | The CLI reads and writes ordered last-selected repositories across fresh XPC connections and applies them to empty tasks through repository batches with ordered roots and default auto/main/main branch settings; a newly saved list applies to a fresh task and remains saved. Invalid repository paths are rejected without changing the saved preference. In the UI, the picker placeholder shows saved repository names in order followed immediately by a Return key indicator; blank Return restores the saved repositories, while typing and arrow selection replaces and persists the list for the next conversation.
    func test_new_task_remembers_last_selected_repositories() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-last-repositories", "--repo", fixture.secondary.path, "--repo", fixture.primary.path])

        openNewTaskConversation()
        let search = element("conversation-repository-search")
        XCTAssertEqual(search.placeholderValue, "secondary, primary ↵", "The conversation picker should show the saved repository order followed by the Return key indicator.")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-primary").waitForExistence(timeout: 10))
        let firstTask = try XCTUnwrap(tasksFromBoardList().first)
        let firstTaskID = try XCTUnwrap(firstTask["id"] as? String)
        let firstRoots = try XCTUnwrap(firstTask["workspaceRoots"] as? [String])
        let firstRepositories = try XCTUnwrap(firstTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(firstRoots, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(firstRepositories.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(firstRepositories.map { $0["branch"] as? String }, ["auto", "auto"])
        XCTAssertEqual(firstRepositories.map { $0["branchFrom"] as? String }, ["main", "main"])
        XCTAssertEqual(firstRepositories.map { $0["mergeTarget"] as? String }, ["main", "main"])
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String], [fixture.secondary.path, fixture.primary.path])
        element("back-to-board-button").click()
        XCTAssertNil(try taskRecord(id: firstTaskID), "Backing out of an empty new conversation should discard that task.")

        openNewTaskConversation()
        let overrideSearch = element("conversation-repository-search")
        XCTAssertTrue((overrideSearch.placeholderValue ?? "").contains("secondary, primary"))
        replaceText(overrideSearch, with: "alternate")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitForExistence(timeout: 10))
        overrideSearch.typeKey(.downArrow, modifierFlags: [])
        overrideSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation-repository-badge-alternate").waitForExistence(timeout: 10))
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String], [fixture.alternate.path])
        XCTAssertEqual(try XCTUnwrap(tasksFromBoardList().first?["workspaceRoots"] as? [String]), [fixture.alternate.path])
        element("back-to-board-button").click()

        openNewTaskConversation()
        let persistedSearch = element("conversation-repository-search")
        XCTAssertTrue((persistedSearch.placeholderValue ?? "").contains("alternate"), "The overridden repository should be the next conversation default.")
        persistedSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation-repository-badge-alternate").waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(tasksFromBoardList().first?["workspaceRoots"] as? [String]), [fixture.alternate.path])
        element("back-to-board-button").click()

        openNewTaskConversation()
        let typedSearch = element("conversation-repository-search")
        replaceText(typedSearch, with: "primary")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitForExistence(timeout: 10))
        typedSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation-repository-badge-primary").waitForExistence(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(tasksFromBoardList().first?["workspaceRoots"] as? [String]), [fixture.primary.path])
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String], [fixture.primary.path])
        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "New conversation restores and remembers repository choices")
    }

    // case-contract: test_new_task_repository_restore_is_atomic_on_invalid_default | Applying an ordered repository batch with a valid repository followed by an empty Git repository fails without mutation: the CLI reports invalid_argument and fresh reads show no repository attachments or workspace roots; New Task blank Return keeps the picker open, shows an error, attaches neither repository, keeps roots empty, and preserves the saved repository order.
    func test_new_task_repository_restore_is_atomic_on_invalid_default() throws {
        launchApp(defaultParent: fixture.parent.path)
        let savedDefaults = [fixture.primary.path, fixture.emptyGitRepository.path]
        let preferenceUpdate = try runCLI([
            "settings", "set-last-repositories",
            "--repo", savedDefaults[0],
            "--repo", savedDefaults[1],
        ])
        XCTAssertEqual(preferenceUpdate["ok"] as? Bool, true)

        openNewTaskConversation()
        let search = element("conversation-repository-search")
        XCTAssertTrue((search.placeholderValue ?? "").contains("primary, empty-git-repo"))
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10), "The failed saved-repository batch should display an error.")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "A failed restore should leave the repository picker open.")
        XCTAssertFalse(element("conversation-repository-badge-primary").exists, "The first valid repository must not remain attached after the batch fails.")
        XCTAssertFalse(element("conversation-repository-badge-empty-git-repo").exists)

        let task = try XCTUnwrap(tasksFromBoardList().first, "New Task should create its empty conversation before restoring repositories.")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let freshTask = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], [], "The failed batch must leave the task without roots.")
        XCTAssertEqual((freshTask["repositoryWorktrees"] as? [[String: Any]])?.count, 0, "The failed batch must leave the task without repository attachments.")
        let settings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(settings?["lastSelectedRepositories"] as? [String], savedDefaults, "A failed restore must preserve the user's ordered repository defaults.")

        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "Failed repository restore leaves the empty new conversation unchanged")
    }

    // case-contract: test_task_roots_remain_after_default_parent_is_cleared | Clearing the default parent does not change roots already saved on a task.
    func test_task_roots_remain_after_default_parent_is_cleared() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Roots survive settings", roots: [fixture.primary.path, fixture.secondary.path])
        openTask(named: "Roots survive settings")
        let savedRoots = try XCTUnwrap(taskRecord(named: "Roots survive settings")?["workspaceRoots"] as? [String])
        assertOrderedRoots(savedRoots)
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
        assertOrderedRoots(savedRoots)
        let settings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(settings?["defaultParentFolder"] as? String)
        let roots = try runCLI(["task", "roots", "get", try taskID(named: "Roots survive settings")])["result"] as? [String: Any]
        XCTAssertEqual(roots?["roots"] as? [String], [fixture.primary.path, fixture.secondary.path])
        attachScreenshot(named: "Existing task roots survive clearing the default parent")
    }

    // case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, verifies empty history, and deletes it cleanly. New Task opens one empty conversation with its repository picker focused and no create sheet. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    func test_new_task_has_empty_conversation_history() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        XCTAssertEqual(app.windows.count, 1, "New Task should open one conversation window.")
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 10), "The new conversation should open its repository picker automatically.")
        repositorySearch.typeText("primary")
        XCTAssertEqual(repositorySearch.value as? String, "primary", "Typing without clicking should go to the focused repository search.")
        XCTAssertFalse(element("create-task-button").exists, "Direct task creation should not present a create sheet.")
        XCTAssertFalse(element("workspace-repository-search").exists, "The sheet repository search should not appear.")
        XCTAssertFalse(element("send-message-button").isEnabled, "A task with no working folders cannot send a message.")
        let shell = try XCTUnwrap(tasksFromBoardList().first)
        XCTAssertTrue((shell["workspaceRoots"] as? [String] ?? []).isEmpty, "New Task should persist an empty pending task before repository selection.")

        element("edit-workspace-roots-button").click()
        XCTAssertTrue(element("browse-workspace-roots-button").waitForExistence(timeout: 5))
        element("browse-workspace-roots-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.custom, confirmationButton: "Add Folders")
        element("save-workspace-roots-button").click()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Untitled task"].exists, "An empty conversation should keep its untitled title until the first prompt is added.")
        XCTAssertFalse(element("task-title-generating-loader").exists, "Title generation should not start before the first prompt.")
        XCTAssertFalse(element("pause-response-button").exists)
        XCTAssertFalse(element("continue-response-button").exists)

        let createdTask = try XCTUnwrap(tasksFromBoardList().first)
        let createdTaskID = try XCTUnwrap(createdTask["id"] as? String)
        XCTAssertEqual(createdTask["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertEqual(createdTask["workspaceRoots"] as? [String], [fixture.custom.path])
        let history = try runCLI(["conversation", "history", createdTaskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertNil(history?["diff"])

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertFalse(element("confirm-discard-empty-task-button").exists, "An empty new conversation should return to the board without a discard confirmation.")
        let deleted = try runCLI(["task", "get", createdTaskID], expectedStatus: 3)
        XCTAssertEqual((deleted["error"] as? [String: Any])?["code"] as? String, "not_found")
        attachScreenshot(named: "New conversation shows its empty state")
    }

    // case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while backing out saves an unsent prompt; reopening restores the draft without creating a branch or worktree, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text.
    func test_task_prompt_draft_persists_after_back() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-success-wait").path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Task creation should open its conversation immediately.")
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
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        let titleGenerationReady = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-ready")
        let titleGenerationContinue = URL(fileURLWithPath: codexFixtureExecutable! + ".resolve-continue")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: titleGenerationReady.path) }, timeout: 10), "The real app-server fixture should confirm that title generation is in flight.")
        let tasks = try tasksFromBoardList()
        let task = try XCTUnwrap(tasks.first)
        let taskID = try XCTUnwrap(task["id"] as? String)
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
        let stableTitle = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(stableTitle?["title"] as? String, "Stable draft title", "Returning with the saved draft should not restart title generation.")
        attachScreenshot(named: "Unsent task prompt is saved after returning to backlog")
    }

    // case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline in the composer without sending; multiline prompts persist as typed text, and the CLI/XPC preserves a 15-line draft, and the UI composer expands beyond five lines, stops growing at its 12-line limit, and retains the complete draft while scrolling. Long submitted prompts persist through CLI/XPC, and the UI transcript shows a scrollbar for overflow with scrolling that reveals earlier and later content. Blank drafts cannot be sent or stored, sent prompts persist in conversation history through reload, and backing out immediately after send preserves the submitted prompt as a sent message while title generation is pending. The CLI rejects submitted-prompt saves unless they include nonblank text and In Progress status. The CLI/XPC and UI also recover a submitted prompt that has no Codex thread or active send reservation: the task becomes Blocked, the pending marker clears, and the prompt returns to the composer. Sending to an Untitled auto-branch task derives its branch from the Codex-generated title or from the prompt fallback when title generation fails. During title preparation, CLI/XPC confirms the submitted prompt and conversation thread remain attached to the task, while the UI keeps Pause disabled until the task's conversation client has an interruptible turn. Persistent diagnostics correlate title generation and application outcomes with the task and Codex thread, record failure or skip reasons, and exclude prompt and title text, including text echoed in server errors. Queued follow-ups persist with task and thread identity across fresh CLI/XPC reads, dispatch once after the next completed turn, and disappear from the queue after completion. During an active turn, the UI exposes separate steer and queue actions, sends steering with the active turn ID, and retains the queued follow-up across reopening.
    func test_conversation_composer_rejects_blank_and_supports_live_turn_controls() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Blank message", roots: [fixture.primary.path])
        openTask(named: "Blank message")
        let composer = element("message-composer")
        let sendButton = element("send-message-button")
        let modelPicker = element("model-picker-menu")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10), "The composer should show the selected model next to its send controls.")
        let modelTaskID = try taskID(named: "Blank message")
        let modelResult = try runCLI(["conversation", "models", modelTaskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        let selectedModelName = String(modelPicker.label.split(separator: ":").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = try XCTUnwrap(availableModels.first(where: { ($0["name"] as? String) == selectedModelName || ($0["id"] as? String) == selectedModelName }))
        XCTAssertTrue(modelPicker.label.localizedCaseInsensitiveContains(selectedModel["name"] as? String ?? selectedModelName))
        XCTAssertFalse(sendButton.isEnabled)
        composer.click()
        composer.typeText("First line")
        composer.typeKey(.return, modifierFlags: .shift)
        composer.typeText("Second line")
        XCTAssertEqual(composer.value as? String, "First line\nSecond line", "Shift+Enter should add a line without submitting the composer.")
        let twoLineHeight = composer.frame.height
        for index in 3...5 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let fiveLineHeight = composer.frame.height
        for index in 6...9 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        XCTAssertGreaterThan(composer.frame.height, twoLineHeight, "The composer should grow as a draft gains lines, up to its expanded limit.")
        XCTAssertGreaterThan(composer.frame.height, fiveLineHeight, "The composer should expand beyond the previous five-line limit.")
        for index in 10...12 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let twelveLineHeight = composer.frame.height
        for index in 13...15 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let expectedLongDraft = (["First line", "Second line"] + (3...15).map { "Line \($0)" }).joined(separator: "\n")
        XCTAssertLessThanOrEqual(composer.frame.height, twelveLineHeight + 2, "The composer should stop growing at its 12-line limit and scroll the remaining draft.")
        XCTAssertEqual(composer.value as? String, expectedLongDraft, "The composer should retain all lines after reaching its scroll limit.")
        XCTAssertTrue(element("conversation-scroll-view").exists, "The transcript should expose its scroll view for reading the full conversation.")
        XCTAssertTrue(sendButton.isEnabled)
        assertHelpTag(for: sendButton, equals: "Send message")
        XCTAssertEqual(((try runCLI(["conversation", "history", taskID(named: "Blank message")])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0, "Adding a line must not send a conversation message.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("   ")
        XCTAssertFalse(sendButton.isEnabled, "Whitespace-only messages must not be sent.")

        let taskID = try taskID(named: "Blank message")
        assertCLIError(
            try runCLI(["task", "prompt", taskID, "--text", "Invalid submitted prompt", "--submitted", "true"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["task", "prompt", taskID, "--text", " ", "--status", "In Progress", "--submitted", "true"], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertCLIError(
            try runCLI(["conversation", "send", taskID, "--message", " "], expectedStatus: 2),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        let isLiveIntegration = FileManager.default.fileExists(atPath: "/tmp/stationai-codex-live-ui-integration")
        if !isLiveIntegration {
            app.terminate()
            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-success-wait").path
            let titleFixtureExecutable = try XCTUnwrap(codexFixtureExecutable)
            launchApp(defaultParent: fixture.parent.path)
            let titleTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--repo", fixture.primary.path])["result"] as? [String: Any])
            )
            let titleTaskID = try XCTUnwrap(titleTask["id"] as? String)
            XCTAssertEqual(try repositoryRecord(taskID: titleTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
            XCTAssertEqual(try repositoryRecord(taskID: titleTaskID, repositoryPath: fixture.primary.path)?["isPending"] as? Bool, true)
            openTask(named: "Untitled task")
            let titleComposer = element("message-composer")
            XCTAssertTrue(titleComposer.waitForExistence(timeout: 10))
            let titlePrompt = "Transcript entry " + String(repeating: "Readable chat content for scrolling. ", count: 120)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            titleComposer.click()
            titleComposer.typeText(titlePrompt)
            element("send-message-button").click()
            let titleFixtureReady = URL(fileURLWithPath: titleFixtureExecutable + ".resolve-ready")
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: titleFixtureReady.path) }, timeout: 15), "The title fixture should hold the task in its title-pending state.")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["title"] as? String, "Generating title…")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["savedPrompt"] as? String, titlePrompt)
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["pendingSubmittedPrompt"] as? String, titlePrompt)
            let backButton = element("back-to-board-button")
            XCTAssertTrue(waitUntil({ backButton.isEnabled }, timeout: 5), "Back should become available after the submitted prompt and title placeholder are persisted.")
            backButton.click()
            let titleTaskCard = element("task-card-\(titleTaskID.uppercased())")
            XCTAssertTrue(titleTaskCard.waitForExistence(timeout: 10))
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["title"] as? String, "Generating title…", "The board should retain the title placeholder while title generation is pending.")
            titleTaskCard.click()
            XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
            XCTAssertEqual(element("message-composer").value as? String, "", "A submitted prompt must not reappear as a draft after returning during title generation.")
            XCTAssertTrue(app.staticTexts[titlePrompt].waitForExistence(timeout: 5), "The submitted prompt should remain visible as a conversation message after reopening.")
            XCTAssertTrue(element("pause-response-button").exists, "The reopened task should retain its active-send controls while the Codex thread is being prepared.")
            XCTAssertFalse(element("pause-response-button").isEnabled, "Pause must stay disabled until this task has an interruptible Codex turn.")
            XCTAssertFalse(element("send-message-button").exists, "A second message must not be sent while the submitted prompt is still active.")
            try Data("continue\n".utf8).write(to: URL(fileURLWithPath: titleFixtureExecutable + ".resolve-continue"))
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: titleTaskID)?["title"] as? String) ?? nil) == "Generated fixture title"
            }, timeout: 20), "Sending a prompt from an empty task should persist the Codex-generated title.")
            XCTAssertTrue(waitUntil({
                guard let repository = try? self.repositoryRecord(taskID: titleTaskID, repositoryPath: self.fixture.primary.path) else { return false }
                return repository["branch"] as? String == "generated-fixture-title" && repository["isPending"] as? Bool == false
            }, timeout: 20), "The new auto branch should use the generated task title.")
            try runGit(fixture.primary, "show-ref", "--verify", "--quiet", "refs/heads/generated-fixture-title")
            XCTAssertTrue(waitUntil({
                (try? self.diagnosticEvents().contains { $0["taskID"] as? String == titleTaskID && $0["event"] as? String == "task.title_apply.succeeded" }) == true
            }, timeout: 10), "The generated title application should be logged.")
            XCTAssertEqual(try taskRecord(id: titleTaskID)?["savedPrompt"] as? String, titlePrompt)
            let titleEvents = try diagnosticEvents().filter { $0["taskID"] as? String == titleTaskID }
            let generationStarted = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_generation.started" })
            let generationSucceeded = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_generation.succeeded" })
            let titleApplied = try XCTUnwrap(titleEvents.first { $0["event"] as? String == "task.title_apply.succeeded" })
            XCTAssertEqual(generationStarted["threadID"] as? String, generationSucceeded["threadID"] as? String)
            XCTAssertTrue((generationStarted["threadID"] as? String)?.isEmpty == false)
            XCTAssertTrue((generationSucceeded["threadID"] as? String)?.isEmpty == false)
            XCTAssertEqual(titleApplied["titleSource"] as? String, "codex")
            let serializedTitleEvents = String(data: try JSONSerialization.data(withJSONObject: titleEvents), encoding: .utf8) ?? ""
            XCTAssertFalse(serializedTitleEvents.contains(titlePrompt), "Title diagnostics must not include conversation text.")
            XCTAssertFalse(serializedTitleEvents.contains("Generated fixture title"), "Title diagnostics must not include generated title text.")
            let transcriptScrollView = element("conversation-scroll-view")
            let longPromptMessage = app.staticTexts[titlePrompt]
            XCTAssertTrue(longPromptMessage.waitForExistence(timeout: 5), "The full long prompt should remain present in conversation history.")
            XCTAssertTrue(app.scrollBars.firstMatch.waitForExistence(timeout: 5), "An overflowing transcript should expose a visible scrollbar.")
            let latestPosition = longPromptMessage.frame.minY
            transcriptScrollView.swipeDown()
            XCTAssertTrue(waitUntil({ longPromptMessage.frame.minY > latestPosition + 20 }, timeout: 5), "Scrolling up should reveal earlier content in the long message.")
            let earlierPosition = longPromptMessage.frame.minY
            transcriptScrollView.swipeUp()
            XCTAssertTrue(waitUntil({ longPromptMessage.frame.minY < earlierPosition - 20 }, timeout: 5), "Scrolling down should return to later content in the long message.")
            _ = try runCLI(["task", "rename", titleTaskID, "--title", "Generated title success"])
            element("back-to-board-button").click()

            let recoveryTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--repo", fixture.primary.path])["result"] as? [String: Any])
            )
            let recoveryTaskID = try XCTUnwrap(recoveryTask["id"] as? String)
            openTask(named: "Untitled task")
            let recoveryPrompt = "Recover this prompt after StationAI closes before Codex starts."
            element("message-composer").click()
            element("message-composer").typeText(recoveryPrompt)
            element("send-message-button").click()
            let recoveryFixtureReady = URL(fileURLWithPath: titleFixtureExecutable + ".resolve-ready")
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: recoveryFixtureReady.path) }, timeout: 15))
            XCTAssertEqual(try taskRecord(id: recoveryTaskID)?["codexThreadID"] as? String, nil)
            XCTAssertEqual(try taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"] as? String, recoveryPrompt)
            app.terminate()
            try Data("continue recovery\n".utf8).write(to: URL(fileURLWithPath: titleFixtureExecutable + ".resolve-continue"))
            launchApp(defaultParent: fixture.parent.path)
            let recoveryTaskCard = element("task-card-\(recoveryTaskID.uppercased())")
            XCTAssertTrue(recoveryTaskCard.waitForExistence(timeout: 10))
            recoveryTaskCard.click()
            XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: recoveryTaskID)?["status"] as? String) ?? nil) == "Blocked"
                    && ((try? self.taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"]) is NSNull || (try? self.taskRecord(id: recoveryTaskID)?["pendingSubmittedPrompt"]) == nil)
            }, timeout: 10), "Reopening a task whose send never reached Codex should clear the pending marker and expose the interrupted state.")
            XCTAssertEqual(element("message-composer").value as? String, recoveryPrompt, "A stale submitted prompt should return to the composer for retry.")
            XCTAssertFalse(app.staticTexts[recoveryPrompt].exists, "A turn that never reached Codex should not be shown as a sent message.")

            codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-failure").path
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            let failureTask = try XCTUnwrap(
                (try runCLI(["task", "create", "--title", "Untitled task", "--repo", fixture.primary.path])["result"] as? [String: Any])
            )
            let failureTaskID = try XCTUnwrap(failureTask["id"] as? String)
            XCTAssertEqual(try repositoryRecord(taskID: failureTaskID, repositoryPath: fixture.primary.path)?["branch"] as? String, "auto")
            openTask(named: "Untitled task")
            let failureComposer = element("message-composer")
            XCTAssertTrue(failureComposer.waitForExistence(timeout: 10))
            let failurePrompt = "Explain how repository setup works for new contributors"
            let rpcFailureCountBeforeSend = try diagnosticEvents().filter {
                $0["event"] as? String == "codex.rpc.response.failed" && $0["errorCode"] as? String == "-32042"
            }.count
            failureComposer.click()
            failureComposer.typeText(failurePrompt)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({
                ((try? self.taskRecord(id: failureTaskID)?["title"] as? String) ?? nil) == failurePrompt
            }, timeout: 20), "When title generation fails, the submitted prompt should become the persisted fallback title.")
            XCTAssertTrue(waitUntil({
                guard let repository = try? self.repositoryRecord(taskID: failureTaskID, repositoryPath: self.fixture.primary.path) else { return false }
                return repository["branch"] as? String == "explain-how-repository-setup-works-for-new-contributors" && repository["isPending"] as? Bool == false
            }, timeout: 20), "A failed title generation should derive the new auto branch from its prompt fallback.")
            XCTAssertEqual(
                try runGitOutput(fixture.primary, "branch", "--list", "explain-how-repository-setup-works-for-new-contributors").trimmingCharacters(in: .whitespacesAndNewlines),
                "explain-how-repository-setup-works-for-new-contributors"
            )
            XCTAssertTrue(waitUntil({
                (try? self.diagnosticEvents().contains { $0["taskID"] as? String == failureTaskID && $0["event"] as? String == "task.title_apply.succeeded" }) == true
            }, timeout: 10), "The prompt fallback application should be logged.")
            XCTAssertEqual(try taskRecord(id: failureTaskID)?["savedPrompt"] as? String, failurePrompt)
            let failureTitleEvents = try diagnosticEvents().filter { $0["taskID"] as? String == failureTaskID }
            let titleGenerationFailure = try XCTUnwrap(failureTitleEvents.first { $0["event"] as? String == "task.title_generation.failed" })
            let fallbackApplied = try XCTUnwrap(failureTitleEvents.first { $0["event"] as? String == "task.title_apply.succeeded" })
            XCTAssertEqual(titleGenerationFailure["phase"] as? String, "title-turn")
            XCTAssertTrue((titleGenerationFailure["threadID"] as? String)?.isEmpty == false)
            XCTAssertTrue((titleGenerationFailure["errorDescription"] as? String)?.isEmpty == false)
            XCTAssertTrue((titleGenerationFailure["errorDescription"] as? String)?.contains("Fixture rejected task-title generation.") == true)
            let rpcFailures = try diagnosticEvents().filter {
                $0["event"] as? String == "codex.rpc.response.failed" && $0["errorCode"] as? String == "-32042"
            }
            XCTAssertEqual(rpcFailures.count, rpcFailureCountBeforeSend + 1, "The title turn server error should produce one RPC failure diagnostic.")
            let rpcFailure = try XCTUnwrap(rpcFailures.last)
            XCTAssertEqual(rpcFailure["errorDescription"] as? String, "Codex returned an RPC error.")
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: rpcFailure), encoding: .utf8)?.contains(failurePrompt) == true, "RPC diagnostics must not store server errors that echo conversation text.")
            XCTAssertEqual(fallbackApplied["titleSource"] as? String, "prompt-fallback")
            let serializedFailureTitleEvents = String(data: try JSONSerialization.data(withJSONObject: failureTitleEvents), encoding: .utf8) ?? ""
            XCTAssertFalse(serializedFailureTitleEvents.contains(failurePrompt), "Title diagnostics must not include conversation text.")
            let queuedText = "Follow up after the next turn."
            _ = try runCLI(["conversation", "queue", failureTaskID, "--message", queuedText])
            let reloadedQueue = try runCLI(["conversation", "queue-list", failureTaskID])["result"] as? [[String: Any]]
            XCTAssertEqual(reloadedQueue?.first?["text"] as? String, queuedText, "The queue should persist through a fresh CLI/XPC read.")
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: failurePrompt)
            XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitForExistence(timeout: 10), "The saved queued follow-up should appear after reopening the conversation.")
            app.terminate()
            codexFixtureExecutable = nil
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: "Blank message")
        }
        if isLiveIntegration {
            let livePrompt = "In stationai-primary.txt, append exactly the line `StationAI UI pause marker 6A20F1`. Then run a shell command that executes `sleep 90; printf PAUSE_TEST_FINISHED`. Do not modify any other files. Reply with a short summary after the command finishes."
            let savedPrompt = try runCLI(["task", "prompt", taskID, "--text", livePrompt])["result"] as? [String: Any]
            XCTAssertEqual(savedPrompt?["savedPrompt"] as? String, livePrompt)
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeText(livePrompt)
            XCTAssertTrue(sendButton.isEnabled, "A nonblank draft in a live Codex session should enable Send.")
            sendButton.click()

            let pauseButton = element("pause-response-button")
            XCTAssertTrue(pauseButton.waitForExistence(timeout: 60), "A live turn should replace Send with Pause.")
            XCTAssertTrue(pauseButton.isEnabled, "Pause should be enabled after Codex reports an active turn.")
            XCTAssertTrue(element("steer-current-turn-button").waitForExistence(timeout: 10), "An active turn should offer a distinct steering action.")
            XCTAssertTrue(element("queue-message-after-turn-button").exists, "An active turn should offer a distinct queue action.")
            let steeringText = "Preserve the existing file and stop after the current command."
            composer.click()
            composer.typeText(steeringText)
            element("steer-current-turn-button").click()
            XCTAssertTrue(app.staticTexts[steeringText].waitForExistence(timeout: 10), "Steering should use the active turn and appear as a sent user message.")
            let queuedText = "Afterward, report that the queued message was dispatched."
            composer.click()
            composer.typeText(queuedText)
            element("queue-message-after-turn-button").click()
            XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitForExistence(timeout: 10), "Queueing should persist and visibly distinguish a follow-up from steering.")

            element("back-to-board-button").click()
            openTask(named: "Blank message")
            XCTAssertTrue(element("pause-response-button").waitForExistence(timeout: 30), "Reopening the task should retain the active-turn controls.")
            XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitForExistence(timeout: 10), "The queued follow-up should survive closing and reopening the conversation.")
            XCTAssertEqual(composer.value as? String, "", "A prompt already sent to Codex must not reappear as a composer draft.")
            let reopenedActivity = element("codex-activity-disclosure")
            let visibleThinking = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Thinking", "Running")
            let thinkingExpectation = XCTNSPredicateExpectation(predicate: visibleThinking, object: reopenedActivity)
            XCTAssertEqual(XCTWaiter.wait(for: [thinkingExpectation], timeout: 30), .completed, "An active turn should remain visibly active after leaving and reopening the task.")

            let activityDisclosure = element("codex-activity-disclosure")
            guard activityDisclosure.waitForExistence(timeout: 60) else {
                attachScreenshot(named: "Live turn did not surface Codex activity")
                let liveHistory = try? runCLI(["conversation", "history", taskID])
                let liveRows = ((liveHistory?["result"] as? [String: Any])?["activities"] as? [[String: Any]] ?? [])
                    .map { "\($0["status"] ?? "unknown"): \($0["title"] ?? "untitled")" }
                let task = try taskRecord(named: "Blank message")
                let roots = task?["workspaceRoots"] as? [String] ?? []
                let markerPath = roots.first.map { URL(fileURLWithPath: $0).appendingPathComponent("stationai-primary.txt") }
                let markerPresent = markerPath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("StationAI UI pause marker 6A20F1") ?? false
                XCTFail("The active tool did not appear in the UI. Persisted activity rows: \(liveRows); fixture edit applied: \(markerPresent).")
                return
            }
            let runningTitle = NSPredicate(format: "label CONTAINS %@", "Running 1 task")
            let runningActivityExpectation = XCTNSPredicateExpectation(predicate: runningTitle, object: activityDisclosure)
            XCTAssertEqual(
                XCTWaiter.wait(for: [runningActivityExpectation], timeout: 60),
                .completed,
                "The collapsed activity title should report the current running-task count."
            )
            attachScreenshot(named: "Running response with collapsed Codex activity")
            let activityRow = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "codex-activity-row-", "sleep 90; printf PAUSE_TEST_FINISHED"))
                .firstMatch
            XCTAssertFalse(activityRow.exists, "Activity details should stay collapsed until opened.")
            activityDisclosure.click()
            XCTAssertTrue(activityRow.waitForExistence(timeout: 30), "Opening activity details should show the running command row.")
            attachScreenshot(named: "Running chat composer and expanded Codex activity")

            pauseButton.click()
            let continueButton = element("continue-response-button")
            XCTAssertTrue(continueButton.waitForExistence(timeout: 30), "An interrupted response should offer Continue.")
            attachScreenshot(named: "Paused response with Continue control")
            continueButton.click()
            XCTAssertTrue(sendButton.waitForExistence(timeout: 120), "The continued response should return the composer to Send.")
            let pauseEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pauseButton)
            let continueEnded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: continueButton)
            XCTAssertEqual(
                XCTWaiter.wait(for: [pauseEnded, continueEnded], timeout: 30),
                .completed,
                "A completed response should no longer show Pause or Continue."
            )
            let completedAssistantMessage = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value != ''", "assistant-message-"))
                .firstMatch
            XCTAssertTrue(completedAssistantMessage.waitForExistence(timeout: 30), "Continue should finish the response and show its assistant message in the conversation.")
            attachScreenshot(named: "Continued response completed in the conversation")
        }
        attachScreenshot(named: "Blank composer leaves send disabled")
    }

    // case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, and the task remains In Progress while a send is active.
    func test_conversation_serializes_concurrent_sends() throws {
        let fixtureTemplate = try makeCodexFixture(emptyQuestions: false)
        let sharedFixture = dataDirectory.appendingPathComponent("codex-fixture-concurrent-serial-success-wait")
        try FileManager.default.copyItem(at: fixtureTemplate, to: sharedFixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedFixture.path)
        try "StationAI test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".stationai-codex-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        codexFixtureExecutable = sharedFixture.path
        launchApp(defaultParent: fixture.parent.path)

        let created = try runCLI(["task", "create", "--title", "Concurrent conversation sends", "--repo", fixture.primary.path])
        let task = try XCTUnwrap(created["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertEqual(task["status"] as? String, "Backlog")
        let firstPrompt = "First serialized message."
        let secondPrompt = "Second serialized message."
        let secondCommand = ["conversation", "send", taskID, "--message", secondPrompt]
        let firstReady = URL(fileURLWithPath: sharedFixture.path + ".resolve-ready")
        let firstRelease = URL(fileURLWithPath: sharedFixture.path + ".resolve-continue")
        let secondStarted = URL(fileURLWithPath: sharedFixture.path + ".serial-second-turn-started")
        var secondTurn: RunningCLIProcess?
        defer {
            if FileManager.default.fileExists(atPath: firstReady.path) {
                try? "Release the first serialized turn.\n".write(to: firstRelease, atomically: true, encoding: .utf8)
            }
            if let secondTurn, secondTurn.process.isRunning { secondTurn.process.terminate(); secondTurn.process.waitUntilExit() }
        }

        openTask(named: "Concurrent conversation sends")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        let firstTurnPaused = waitUntil({ FileManager.default.fileExists(atPath: firstReady.path) }, timeout: 15)
        let fixtureHistoryURL = URL(fileURLWithPath: sharedFixture.path + ".history")
        let fixtureHistory = (try? String(contentsOf: fixtureHistoryURL, encoding: .utf8)) ?? "<no history>"
        let fixtureSidecars = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path))?
            .filter { $0.hasPrefix(URL(fileURLWithPath: sharedFixture.path).lastPathComponent) }
            .sorted() ?? []
        XCTAssertTrue(
            firstTurnPaused,
            "The first UI send should pause in the local app-server fixture before the CLI send begins. Fixture sidecars=\(fixtureSidecars); history=\(fixtureHistory)"
        )
        let activeStatus = try XCTUnwrap(taskRecord(id: taskID)?["status"] as? String)
        XCTAssertEqual(activeStatus, "In Progress", "The active UI send should keep the task In Progress.")
        secondTurn = try startCLIProcess(
            secondCommand,
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": sharedFixture.path]
        )
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(secondTurn?.process.isRunning == true, "The second send should wait for the conversation-turn reservation held by the first send.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStarted.path), "The shared app-server fixture must not receive the second turn until the first send releases its reservation.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress", "A queued same-task send must not mark the task Blocked.")

        try "Release the first serialized turn.\n".write(to: firstRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("send-message-button").waitForExistence(timeout: 15), "The UI send should finish after the fixture is released.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: secondStarted.path) }, timeout: 15), "The CLI send should start after the UI turn releases its reservation.")
        let secondResponse = try finishCLIProcess(try XCTUnwrap(secondTurn))
        XCTAssertTrue(secondResponse["ok"] as? Bool == true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStarted.path), "The second app-server turn should begin after the first releases its reservation.")
        let savedHistory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sharedFixture.path + ".history"))) as? [String: Any]
        )
        let persistedPrompts = try XCTUnwrap(savedHistory["messages"] as? [[String: Any]]).compactMap { $0["userMessage"] as? String }
        XCTAssertEqual(persistedPrompts, [firstPrompt, secondPrompt], "Both messages should persist in the same local Codex thread history.")
        let threadID = try XCTUnwrap(savedHistory["threadID"] as? String)
        let protocolEvents = try XCTUnwrap(savedHistory["events"] as? [[String: Any]])
        let threadEvents = protocolEvents.filter { ($0["method"] as? String)?.hasPrefix("thread/") == true }
        XCTAssertEqual(threadEvents.compactMap { $0["method"] as? String }.filter { $0 == "thread/start" }.count, 1)
        XCTAssertGreaterThanOrEqual(threadEvents.compactMap { $0["method"] as? String }.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertTrue(protocolEvents.allSatisfy { $0["threadID"] as? String == threadID })
        let persistedTurns = try XCTUnwrap(savedHistory["messages"] as? [[String: Any]])
        XCTAssertTrue(persistedTurns.allSatisfy { $0["threadID"] as? String == threadID })
        let turnIDs = persistedTurns.compactMap { $0["turnID"] as? String }
        XCTAssertEqual(turnIDs.count, 2)
        XCTAssertEqual(Set(turnIDs).count, 2, "Each concurrent send should use a distinct Codex turn ID.")
        XCTAssertEqual(
            protocolEvents.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["turnID"] as? String },
            turnIDs
        )
        let completed = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(completed["codexThreadID"] as? String, threadID)
        XCTAssertEqual(completed["status"] as? String, "Review")

        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible("Concurrent conversation sends", inColumn: "Review")
        openTask(named: "Concurrent conversation sends")
        XCTAssertTrue(app.staticTexts[firstPrompt].waitForExistence(timeout: 10), "Reopening the task should retain the first completed send in conversation history.")
        XCTAssertTrue(app.staticTexts[secondPrompt].waitForExistence(timeout: 10), "Reopening the task should load the completed second send from the real app-server thread.")
    }

    // case-contract: test_conversation_steers_and_queues_active_turn | While a Codex turn is active, a stale steer response is shown as an error and preserves the draft for retry; CLI/XPC steering routes to a UI-owned active turn and appears in the visible conversation; a subsequent accepted UI Steer action uses the matching active turn ID, appears in the transcript, and clears its draft. The user can also persist a distinct follow-up for after completion; it dispatches once after a matching completed notification, survives fresh CLI/XPC reads, and is removed only after successful delivery.
    func test_conversation_steers_and_queues_active_turn() throws {
        let fixtureTemplate = try makeCodexFixture(emptyQuestions: false)
        let sharedFixture = dataDirectory.appendingPathComponent("codex-fixture-steer-queue-serial-success-wait")
        try FileManager.default.copyItem(at: fixtureTemplate, to: sharedFixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedFixture.path)
        try "StationAI test owns this Codex protocol fixture (v1).\n".write(
            to: dataDirectory.appendingPathComponent(".stationai-codex-fixture-owner"),
            atomically: true,
            encoding: .utf8
        )
        try "reject one stale steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        codexFixtureExecutable = sharedFixture.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Active turn message controls", roots: [fixture.primary.path])
        openTask(named: "Active turn message controls")

        let taskID = try taskID(named: "Active turn message controls")
        let firstPrompt = "Start the active turn before steering and queueing."
        let steeringText = "Keep the current approach and simplify the final change."
        let queuedText = "After the current work, verify the saved follow-up."
        let composer = element("message-composer")
        composer.click()
        composer.typeText(firstPrompt)
        element("send-message-button").click()
        let ready = URL(fileURLWithPath: sharedFixture.path + ".resolve-ready")
        let release = URL(fileURLWithPath: sharedFixture.path + ".resolve-continue")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 15), "The fixture should hold the current turn active.")
        XCTAssertTrue(element("steer-current-turn-button").waitForExistence(timeout: 10))
        XCTAssertTrue(element("queue-message-after-turn-button").exists)

        composer.click()
        composer.typeText(steeringText)
        element("steer-current-turn-button").click()
        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10), "A stale server response should be shown as a steering error.")
        XCTAssertEqual(composer.value as? String, steeringText, "A rejected steering message should remain available for retry.")
        XCTAssertFalse(app.staticTexts[steeringText].exists, "A rejected steering message must not appear as sent.")
        let remoteSteer = try runCLI(["conversation", "steer", taskID, "--message", steeringText])["result"] as? [String: Any]
        XCTAssertEqual(remoteSteer?["accepted"] as? Bool, true, "CLI/XPC steering should route to the UI-owned active turn.")
        XCTAssertTrue(app.staticTexts[steeringText].waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "", "A successful XPC steer should clear the matching draft in the visible composer.")
        let uiSteeringText = "Make the final change concise and focused."
        composer.click()
        composer.typeText(uiSteeringText)
        element("steer-current-turn-button").click()
        XCTAssertTrue(app.staticTexts[uiSteeringText].waitForExistence(timeout: 10), "An accepted UI steer should appear in the visible transcript.")
        XCTAssertEqual(composer.value as? String, "", "An accepted UI steer should clear the submitted draft.")
        composer.click()
        composer.typeText(queuedText)
        element("queue-message-after-turn-button").click()
        XCTAssertTrue(app.staticTexts["Queued for after this turn"].waitForExistence(timeout: 10))
        let queued = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        XCTAssertEqual(queued?.count, 1)
        XCTAssertEqual(queued?.first?["text"] as? String, queuedText)

        try "Release the active turn.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The queued message should dispatch once after the matching completed notification.")
        let history = try runCLI(["conversation", "history", taskID], extraEnvironment: [
            "STATIONAI_E2E_CODEX_EXECUTABLE": sharedFixture.path
        ])["result"] as? [String: Any]
        let userMessages = (history?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(userMessages.compactMap { $0["text"] as? String }.filter { $0 == queuedText }.count, 1)
        let fixtureHistory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: sharedFixture.path + ".history"))) as? [String: Any]
        )
        let steerRequests = try XCTUnwrap(fixtureHistory["steerRequests"] as? [[String: Any]])
        XCTAssertEqual((fixtureHistory["rejectedSteerRequests"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(steerRequests.count, 2)
        let activeTurnID = (fixtureHistory["messages"] as? [[String: Any]])?.first?["turnID"] as? String
        XCTAssertEqual(steerRequests[0]["expectedTurnId"] as? String, activeTurnID)
        XCTAssertEqual(steerRequests[0]["input"] as? [[String: String]], [["type": "text", "text": steeringText]])
        XCTAssertEqual(steerRequests[1]["expectedTurnId"] as? String, activeTurnID, "The UI Steer action must include the current turn ID.")
        XCTAssertEqual(steerRequests[1]["input"] as? [[String: String]], [["type": "text", "text": uiSteeringText]])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 10))
    }

    // case-contract: test_conversation_sends_image_attachments | The conversation composer accepts images from the picker and paste, previews them before sending, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, and displays attached images from reloaded conversation history. Diagnostics record image MIME and encoded size without storing image payloads.

    func test_conversation_sends_image_attachments() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Image conversation", roots: [fixture.primary.path])
        openTask(named: "Image conversation")
        let image = dataDirectory.appendingPathComponent("chat-image.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let attach = element("attach-chat-image-button")
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attach.click()
        let picker = app.sheets["open-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Attach should open the system image picker.")
        picker.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5))
        try chooseFile(in: picker, goToSheet: goToSheet, file: image)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "The chosen image should appear in the composer preview.")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("What is shown in this screenshot?")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        let pickedTurnData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))
        let pickedTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: pickedTurnData) as? [String: Any])
        XCTAssertEqual(pickedTurn["userMessage"] as? String, "What is shown in this screenshot?")
        XCTAssertEqual((pickedTurn["images"] as? [String])?.count, 1, "The fixture should receive the picker image alongside the text prompt.")
        let pickedImage = try XCTUnwrap((pickedTurn["images"] as? [String])?.first)
        XCTAssertTrue(pickedImage.hasPrefix("data:image/png;base64,"), "The fixture should receive the image as a data URL.")
        XCTAssertEqual(pickedTurn["imageInputs"] as? [[String: String]], [["type": "image", "url": pickedImage]], "The Codex request should use the tagged image URL payload.")
        var imageDiagnostics = try diagnosticEvents()
        let pickedImageLog = try XCTUnwrap(imageDiagnostics.first {
            $0["event"] as? String == "bridge.request.succeeded"
                && $0["command"] as? String == "conversation.send"
                && $0["argument.images.0.mime"] as? String == "image/png"
        })
        XCTAssertGreaterThan(Int(pickedImageLog["argument.images.0.encodedCharacterCount"] as? String ?? "0") ?? 0, 0)
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: imageDiagnostics), encoding: .utf8)?.contains(pickedImage) ?? true)
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture").waitForExistence(timeout: 10), "Reloaded history should retain the picker attachment.")
        XCTAssertTrue(app.images["user-message-item_user_fixture"].waitForExistence(timeout: 10), "Conversation history should render the picker image.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
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
        let largeImage = NSImage(size: NSSize(width: 3000, height: 1500))
        largeImage.addRepresentation(largeBitmap)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([largeImage])
        let pastedComposer = element("message-composer")
        pastedComposer.click()
        pastedComposer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "Pasting an image should create a composer preview.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture").waitForExistence(timeout: 10), "History reload should leave the pasted attachment in the conversation.")
        XCTAssertTrue(app.images["user-message-item_user_fixture"].waitForExistence(timeout: 10), "Conversation history should render the pasted image itself.")
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

    // case-contract: test_conversation_rejects_invalid_image_attachments | Malformed image data is rejected with a visible composer error and an invalid_argument bridge response, without creating conversation history or advancing task status.
    func test_conversation_rejects_invalid_image_attachments() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Invalid image conversation", roots: [fixture.primary.path])
        openTask(named: "Invalid image conversation")
        let invalid = dataDirectory.appendingPathComponent("invalid-chat-image.png")
        try Data("not an image".utf8).write(to: invalid)
        element("attach-chat-image-button").click()
        let picker = app.sheets["open-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = app.sheets.firstMatch
        XCTAssertTrue(goToSheet.waitForExistence(timeout: 5))
        try chooseFile(in: picker, goToSheet: goToSheet, file: invalid)
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Pasting malformed image bytes should show a visible validation error.")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("valid images"))
        XCTAssertTrue(element("send-message-button").isEnabled == false, "An invalid image must not enable send.")

        let taskID = try taskID(named: "Invalid image conversation")
        let bridgeResult = try runCLI(["conversation", "send", taskID, "--image", invalid.path], expectedStatus: 2)
        XCTAssertEqual((bridgeResult["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Backlog")
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
    }

    // case-contract: test_conversation_shows_subagent_delegation | When Codex delegates a task to a subagent, the conversation activity shows the delegated task and its completion status during the turn and after history reload. Diagnostics record Codex RPC outcomes and command working directory and file-change paths while excluding conversation text, command output, and diffs.
    func test_conversation_shows_subagent_delegation() throws {
        let fixtureRoot = WorkspaceFixture.root
        let fixtureOwnerMarker = fixtureRoot.appendingPathComponent(".stationai-bridge-fixture")
        XCTAssertEqual(
            try String(contentsOf: fixtureOwnerMarker, encoding: .utf8),
            "StationAI bridge tests own this deterministic fixture (v1).\n",
            "Refusing to place the Codex fixture in a directory StationAI does not own."
        )
        let fixtureCopy = fixtureRoot.appendingPathComponent("codex-fixture-subagent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the subagent fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["task", "create", "--title", "Subagent delegation", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Subagent delegation")
        openTask(named: "Subagent delegation")
        let prompt = "Delegate this task."
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText(prompt)
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review"
        }, timeout: 20), "The visible composer turn should finish and persist the task status.")
        let codexDiagnostics = try diagnosticEvents()
        XCTAssertTrue(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.request.started" && $0["method"] as? String == "turn/start"
        })
        XCTAssertTrue(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.response.succeeded" && $0["method"] as? String == "turn/start"
        })
        let commandDiagnostic = try XCTUnwrap(codexDiagnostics.first {
            $0["event"] as? String == "codex.notification"
                && $0["method"] as? String == "item/completed"
                && $0["itemType"] as? String == "commandExecution"
        })
        XCTAssertEqual(commandDiagnostic["command"] as? String, "git status --short")
        XCTAssertEqual(commandDiagnostic["workingDirectory"] as? String, fixture.primary.resolvingSymlinksInPath().path)
        XCTAssertGreaterThan(Int(commandDiagnostic["outputBytes"] as? String ?? "0") ?? 0, 0)
        let fileDiagnostic = try XCTUnwrap(codexDiagnostics.first {
            $0["event"] as? String == "codex.notification"
                && $0["method"] as? String == "item/completed"
                && $0["itemType"] as? String == "fileChange"
        })
        XCTAssertEqual(fileDiagnostic["changedPathCount"] as? String, "1")
        XCTAssertEqual(fileDiagnostic["changedPaths"] as? String, "README.md")
        XCTAssertEqual(fileDiagnostic["changeKinds"] as? String, "update")
        let serializedCodexDiagnostics = String(data: try JSONSerialization.data(withJSONObject: codexDiagnostics), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_OUTPUT_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_DIFF_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains(prompt), "Diagnostics must not store the conversation text.")

        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "StationAI must be foreground before inspecting the conversation.")

        let activityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(activityDisclosure.waitForExistence(timeout: 20), "A delegated task should appear in conversation activity.")
        activityDisclosure.click()
        let activityRow = element("codex-activity-row-item_stationai_subagent")
        XCTAssertTrue(activityRow.waitForExistence(timeout: 10))
        XCTAssertTrue(activityRow.label.contains("Task delegated to subagent"))
        XCTAssertTrue(activityRow.label.contains("Completed"))
        let activityDetail = element("codex-activity-detail-item_stationai_subagent")
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 5))
        let detailDescription = "\(activityDetail.label) \(activityDetail.value as? String ?? "")"
        XCTAssertTrue(detailDescription.contains("Inspect the project structure and report relevant files."))
        attachScreenshot(named: "Conversation shows a completed subagent delegation")
    }

    // case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode sends a planning turn; a completed <proposed_plan> is automatically rendered as Markdown without exposing its wrapper tags, including after reopening, while bridge history preserves the exact source and the reopened conversation shows its latest message.
    func test_plan_mode_renders_markdown_in_conversation() throws {
        let fixtureRoot = WorkspaceFixture.root
        let fixtureOwnerMarker = fixtureRoot.appendingPathComponent(".stationai-bridge-fixture")
        XCTAssertEqual(
            try String(contentsOf: fixtureOwnerMarker, encoding: .utf8),
            "StationAI bridge tests own this deterministic fixture (v1).\n",
            "Refusing to use a Codex fixture in a directory StationAI does not own."
        )
        let fixtureCopy = fixtureRoot.appendingPathComponent("codex-fixture-markdown")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureCopy.path), "The UI runner must prepare the Markdown fixture before launch.")
        codexFixtureExecutable = fixtureCopy.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Plan mode Markdown", roots: [fixture.primary.path])
        openTask(named: "Plan mode Markdown")

        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 10))
        modeMenu.click()
        let planMode = app.menuItems["Plan mode"]
        XCTAssertTrue(planMode.waitForExistence(timeout: 5))
        planMode.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))

        let composer = element("message-composer")
        composer.click()
        composer.typeText("Plan the task.")
        element("send-message-button").click()
        let taskID = try taskID(named: "Plan mode Markdown")
        let markdownReply = "<proposed_plan>\n## Implementation plan\n\nStart with the **workspace model**.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n</proposed_plan>"
        let assistantMarkdown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Implementation plan"))
            .firstMatch
        XCTAssertTrue(assistantMarkdown.waitForExistence(timeout: 30), "The Plan mode response should appear in the conversation.")
        XCTAssertFalse(assistantMarkdown.label.contains("<proposed_plan>"), "The plan should be shown automatically without its protocol wrapper.")
        XCTAssertFalse(assistantMarkdown.label.contains("</proposed_plan>"), "The closing protocol wrapper should not be visible.")

        element("back-to-board-button").click()
        openTask(named: "Plan mode Markdown")
        let reloadedHistory = try runCLI(
            ["conversation", "history", taskID],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
        )["result"] as? [String: Any]
        let reloadedMessages = reloadedHistory?["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(reloadedMessages.contains { $0["role"] as? String == "assistant" && $0["text"] as? String == markdownReply }, "The exact Markdown source should persist after reopening the plan conversation.")
        XCTAssertEqual(reloadedMessages.last?["role"] as? String, "assistant", "The bridge history should keep the latest response last.")
        let reloadedAssistant = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Implementation plan"))
            .firstMatch
        XCTAssertTrue(reloadedAssistant.waitForExistence(timeout: 10), "The completed plan should appear automatically after reopening.")
        XCTAssertFalse(reloadedAssistant.label.contains("<proposed_plan>"), "The reloaded plan should hide its opening protocol wrapper.")
        XCTAssertFalse(reloadedAssistant.label.contains("</proposed_plan>"), "The reloaded plan should hide its closing protocol wrapper.")
        let heading = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-markdown-heading-"))
            .firstMatch
        let listItems = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant-markdown-list-item-"))
        let firstListItem = listItems.element(boundBy: 0)
        let secondListItem = listItems.element(boundBy: 1)
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Plan headings should render as distinct elements after reopening.")
        XCTAssertTrue(accessibleLabelOrValue(of: heading).contains("Implementation plan"), "The rendered heading should retain the plan title after reopening.")
        XCTAssertTrue(firstListItem.waitForExistence(timeout: 5), "The first plan list entry should render after reopening.")
        XCTAssertTrue(accessibleLabelOrValue(of: firstListItem).contains("Implementation detail 01"))
        XCTAssertTrue(secondListItem.waitForExistence(timeout: 5), "The second plan list entry should render after reopening.")
        XCTAssertTrue(accessibleLabelOrValue(of: secondListItem).contains("Implementation detail 02"))
        let latestListItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Final verification: confirm the latest message is visible after reopening"))
            .firstMatch
        let conversationScrollView = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            latestListItem.frame.maxY <= conversationScrollView.frame.maxY + 2
                && latestListItem.frame.maxY > conversationScrollView.frame.minY
        }, timeout: 5), "Reopening a long conversation should position its final message in the visible viewport.")
        attachScreenshot(named: "Plan mode response renders a structured Markdown plan")
    }

    // case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer shows a Codex-reported model, while unsupported modes and malformed model IDs are rejected before creating history.
    func test_conversation_mode_rejects_unknown_mode_without_starting_a_turn() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Conversation modes", roots: [fixture.primary.path])
        openTask(named: "Conversation modes")

        let taskID = try taskID(named: "Conversation modes")
        let modelResult = try runCLI(["conversation", "models", taskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        XCTAssertFalse(availableModels.isEmpty)
        let modelMenu = element("model-picker-menu")
        XCTAssertTrue(modelMenu.waitForExistence(timeout: 10))
        let selectedModelName = String(modelMenu.label.split(separator: ":").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = try XCTUnwrap(availableModels.first(where: { ($0["name"] as? String) == selectedModelName || ($0["id"] as? String) == selectedModelName }))
        let selectedModelID = try XCTUnwrap(selectedModel["id"] as? String)
        XCTAssertTrue(modelMenu.label.localizedCaseInsensitiveContains(selectedModelName))
        if let alternateModel = availableModels.first(where: { $0["id"] as? String != selectedModelID }) {
            let alternateID = try XCTUnwrap(alternateModel["id"] as? String)
            modelMenu.click()
            let optionID = "model-option-\(alternateID)"
            let modelOption = app.menuItems.matching(identifier: optionID).firstMatch
            XCTAssertTrue(modelOption.waitForExistence(timeout: 5), "The model picker should list each model returned by Codex.")
            modelOption.click()
            let updatedModelPicker = element("model-picker-menu")
            XCTAssertTrue(updatedModelPicker.waitForExistence(timeout: 5))
            XCTAssertTrue(updatedModelPicker.label.localizedCaseInsensitiveContains(alternateModel["name"] as? String ?? alternateID), "Choosing a model should update the composer selection.")
        }

        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 10))
        modeMenu.click()
        let planMode = app.menuItems["Plan mode"]
        XCTAssertTrue(planMode.waitForExistence(timeout: 5))
        planMode.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))

        let composer = element("message-composer")
        composer.click()
        composer.typeText("/plan")
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Typing /plan should switch modes without sending a message.")

        assertCLIError(
            try runCLI(
                ["conversation", "send", taskID, "--message", "Hello", "--mode", "unsupported"],
                expectedStatus: 2
            ),
            code: "invalid_argument"
        )
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["messages"] as? [Any])?.count, 0)
        XCTAssertEqual((history?["activities"] as? [Any])?.count, 0)
        attachScreenshot(named: "Plan mode is visible in the conversation composer")
    }

    // case-contract: test_codex_questions_can_be_answered_over_cli_xpc | Structured questions raised in Plan mode move the task into the conditional Waiting Response board section even when Codex marks the request non-blocking; reopening preserves its status, keyed answers resume In Progress, and successful completion moves it to Review.
    func test_codex_questions_can_be_answered_over_cli_xpc() throws {
        let created = try runCLI(["task", "create", "--title", "Codex questions", "--root", fixture.primary.path])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-plan-slow").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Codex questions")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 5))
        modeMenu.click()
        app.menuItems["Plan mode"].click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"))
        element("message-composer").click()
        element("message-composer").typeText("Please share your plan.")
        element("send-message-button").click()

        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Which color should I use?"].exists)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response")
        XCTAssertTrue(element("column-heading-waiting-response").waitForExistence(timeout: 5))
        let waitingResponseColumn = element("column-waiting-response")
        let waitingTaskCard = waitingResponseColumn.buttons["task-card-\(taskID.uppercased())"]
        XCTAssertTrue(waitingTaskCard.waitForExistence(timeout: 8), "The created task is not in Waiting Response.")
        let inProgressColumn = element("column-in-progress")
        let boardViewport = element("board-columns-scroll-view")
        XCTAssertTrue(waitUntil({ waitingResponseColumn.frame.maxY < inProgressColumn.frame.minY }, timeout: 5), "Waiting Response should settle above In Progress after the board animation.")
        XCTAssertGreaterThanOrEqual(waitingResponseColumn.frame.minY, boardViewport.frame.minY)
        XCTAssertLessThanOrEqual(inProgressColumn.frame.maxY, boardViewport.frame.maxY)
        XCTAssertLessThan(waitingTaskCard.frame.height, 200, "A task card's accessibility target should match the visible card instead of filling the column.")
        attachScreenshot(named: "Waiting Response appears above In Progress while a task awaits an answer")
        waitingTaskCard.click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 5), "Reopening the task should restore the pending question.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Waiting Response", "Reopening a pending Plan-mode question must preserve Waiting Response.")
        XCTAssertFalse(element("submit-ai-answers-button").isEnabled, "Blank answers must not be submitted.")
        app.buttons["Blue"].click()
        let secretAnswer = element("ai-question-answer-token")
        XCTAssertTrue(secretAnswer.exists)
        secretAnswer.click()
        secretAnswer.typeText("fixture-secret")
        attachScreenshot(named: "Codex structured questions with option and private answer fields")
        element("submit-ai-answers-button").click()

        let resumeDeadline = Date().addingTimeInterval(5)
        var resumedStatus: String?
        while Date() < resumeDeadline {
            resumedStatus = try taskRecord(id: taskID)?["status"] as? String
            if resumedStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(resumedStatus, "In Progress", "Submitting the blocking answer should resume the task before the turn completes.")

        let completionDeadline = Date().addingTimeInterval(10)
        var completedStatus: String?
        while Date() < completionDeadline {
            completedStatus = try taskRecord(id: taskID)?["status"] as? String
            if completedStatus == "Review" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Review", "The submitted answer should complete the task into Review.")
        XCTAssertFalse(element("ai-question-form-title").exists)
    }

    // case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section and completes the task into Review.
    func test_codex_empty_question_request_is_rejected() throws {
        let created = try runCLI(["task", "create", "--title", "Empty Codex questions", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let emptyFixture = try makeCodexFixture(emptyQuestions: true).path
        let failedTurn = try runCLI(
            ["conversation", "send", taskID, "--message", "Please ask your questions."],
            expectedStatus: 1,
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": emptyFixture]
        )
        XCTAssertFalse(failedTurn["ok"] as? Bool ?? true)
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Blocked")
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("column-heading-blocked").waitForExistence(timeout: 5))
        XCTAssertTrue(element("blocked-waiting-indicator").exists)
        assertTaskVisible("Empty Codex questions", inColumn: "Blocked")
        let boardViewport = element("board-columns-scroll-view")
        let blockedColumn = element("column-blocked")
        let backlogColumn = element("column-backlog")
        XCTAssertLessThan(blockedColumn.frame.maxY, backlogColumn.frame.minY)
        XCTAssertGreaterThanOrEqual(blockedColumn.frame.minY, boardViewport.frame.minY)
        XCTAssertLessThanOrEqual(backlogColumn.frame.maxY, boardViewport.frame.maxY)
        attachScreenshot(named: "Blocked task appears above Backlog while waiting for user intervention")
        let retryFixture = try makeCodexFixture(emptyQuestions: false).path
        _ = try runCLI(
            ["conversation", "send", taskID, "--message", "Retry this task.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": retryFixture]
        )
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Review")
        XCTAssertTrue(waitForDisappearance(element("column-heading-blocked")), "The blocked section should disappear after the task is unblocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
    }

    // case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions remain visible without moving the task out of In Progress, then successful completion moves it to Review.
    func test_codex_nonblocking_question_keeps_task_in_progress() throws {
        _ = try runCLI(["task", "create", "--title", "Non-blocking question", "--root", fixture.primary.path])
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-nonblocking-slow").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Non-blocking question")
        element("message-composer").click()
        element("message-composer").typeText("Ask non-blocking questions.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "In Progress")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        let nonblockingDeadline = Date().addingTimeInterval(5)
        var nonblockingStatus: String?
        while Date() < nonblockingDeadline {
            nonblockingStatus = try taskRecord(named: "Non-blocking question")?["status"] as? String
            if nonblockingStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(nonblockingStatus, "In Progress", "A non-blocking answer should leave the task active until the turn completes.")
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "Review")
    }

    // case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; reopening while a turn is still active recovers the stale task to Blocked with a reason. Interrupted outcomes persist Blocked across connections, and diagnostics identify the failed turn phase and store path; a new prompt can finish in Review. A queued follow-up remains visible as needing action after interruption, survives reopening, and is dispatched only after an explicit retry; the completed retry becomes the task's latest saved prompt.
    func test_codex_interrupted_turn_blocks_with_reason_and_can_retry() throws {
        _ = try runCLI(["task", "create", "--title", "Interrupted turn", "--root", fixture.primary.path])
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-interrupted").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Interrupted turn")
        element("message-composer").click()
        element("message-composer").typeText("Start work that will be interrupted.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        let interruptedID = try taskID(named: "Interrupted turn")
        let queuedText = "Follow up after I review the interrupted turn."
        let queued = try runCLI(["conversation", "queue", interruptedID, "--message", queuedText])["result"] as? [String: Any]
        let queuedID = try XCTUnwrap(queued?["id"] as? String)
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()

        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Follow-up needs your action"].waitForExistence(timeout: 10), "An interrupted turn must retain its queued message for an explicit retry.")
        let blocked = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(blocked["status"] as? String, "Blocked")
        XCTAssertTrue((blocked["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)
        let sendFailure = try XCTUnwrap(diagnosticEvents().first {
            $0["event"] as? String == "conversation.send.failed" && $0["taskID"] as? String == interruptedID
        })
        XCTAssertEqual(sendFailure["phase"] as? String, "codex-turn")
        XCTAssertEqual(sendFailure["storePath"] as? String, dataDirectory.appendingPathComponent("StationAI-v2.store").path)

        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        openTask(named: "Interrupted turn")
        let reopened = try XCTUnwrap(taskRecord(named: "Interrupted turn"))
        XCTAssertEqual(reopened["status"] as? String, "Blocked")
        XCTAssertTrue((reopened["statusMessage"] as? String)?.localizedCaseInsensitiveContains("interrupted") == true)
        element("message-composer").click()
        element("message-composer").typeText("Retry the interrupted task.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: "Interrupted turn")?["status"] as? String, "Review")
        let retryQueuedButton = element("retry-queued-message-\(queuedID.uppercased())")
        XCTAssertTrue(retryQueuedButton.waitForExistence(timeout: 10), "The retained follow-up should remain explicitly retryable after reopening and completing a new turn.")
        retryQueuedButton.click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10), "Explicit retry should submit the queued message to Codex.")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil({
            (((try? self.runCLI(["conversation", "queue-list", interruptedID])["result"] as? [[String: Any]]) ?? [])).isEmpty
        }, timeout: 10), "A completed explicit retry should remove the queued item.")
        XCTAssertEqual(try taskRecord(id: interruptedID)?["savedPrompt"] as? String, queuedText, "The successfully retried follow-up should become the latest saved prompt.")

        _ = try runCLI(["task", "create", "--title", "Reopen active turn", "--root", fixture.primary.path])
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-hold").path
        app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        relaunchApp()
        openTask(named: "Reopen active turn")
        element("message-composer").click()
        element("message-composer").typeText("Leave this turn active while StationAI closes.")
        element("send-message-button").click()
        let activeDeadline = Date().addingTimeInterval(10)
        var activeStatus: String?
        while Date() < activeDeadline {
            activeStatus = try taskRecord(named: "Reopen active turn")?["status"] as? String
            if activeStatus == "In Progress" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(activeStatus, "In Progress")
        attachScreenshot(named: "Task remains In Progress while the Codex turn is active")

        relaunchApp()
        openTask(named: "Reopen active turn")
        let recovered = try XCTUnwrap(taskRecord(named: "Reopen active turn"))
        XCTAssertEqual(recovered["status"] as? String, "Blocked")
        XCTAssertTrue((recovered["statusMessage"] as? String)?.localizedCaseInsensitiveContains("reopened before codex") == true)
        attachScreenshot(named: "Reopening StationAI recovers a stale In Progress task as Blocked")
    }

    // case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view separates staged and working Git changes, and selecting text or JSON files opens a calculated, highlighted side-by-side diff over the conversation. Diagnostics record inventory and file-read outcomes with paths and byte counts, without logging file contents.
    func test_task_workspace_changes_group_staged_and_unstaged_diffs() throws {
        _ = try runCLI([
            "task", "create", "--title", "Git changes", "--root", fixture.changes.path
        ])
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Git changes")

        XCTAssertTrue(element("staged-changes-section").waitForExistence(timeout: 10))
        XCTAssertTrue(element("working-changes-section").exists)
        XCTAssertTrue(element("workspace-change-staged-shared.txt").exists)
        XCTAssertTrue(element("workspace-change-working-shared.txt").exists)
        XCTAssertTrue(element("workspace-change-working-untracked.txt").exists)
        XCTAssertTrue(element("workspace-change-working-deleted.txt").exists)
        XCTAssertTrue(element("workspace-change-working-syntax.json").exists)
        XCTAssertTrue(element("workspace-change-staged-staged-deleted.txt").exists)

        let taskID = try taskID(named: "Git changes")
        let inventory = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((inventory?["staged"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((inventory?["working"] as? [[String: Any]])?.count, 5)
        let stagedDiff = try runCLI([
            "task", "changes", "diff", taskID,
            "--repository", fixture.changes.path,
            "--path", "shared.txt",
            "--group", "staged"
        ])["result"] as? [String: Any]
        XCTAssertEqual(stagedDiff?["original"] as? String, "Shared baseline.\n")
        XCTAssertEqual(stagedDiff?["modified"] as? String, "Shared index version.\n")
        assertCLIError(
            try runCLI([
                "task", "changes", "diff", taskID,
                "--repository", fixture.changes.path,
                "--path", "stale.txt",
                "--group", "working",
            ], expectedStatus: 3),
            code: "not_found"
        )
        let changeDiagnostics = try diagnosticEvents()
        XCTAssertTrue(changeDiagnostics.contains {
            $0["event"] as? String == "workspace.files.inventory.succeeded"
                && $0["stagedCount"] as? String == "3"
                && $0["workingCount"] as? String == "5"
        })
        let stagedRead = try XCTUnwrap(changeDiagnostics.first {
            $0["event"] as? String == "workspace.file.read.succeeded"
                && $0["path"] as? String == "shared.txt"
                && $0["group"] as? String == "staged"
        })
        XCTAssertGreaterThan(Int(stagedRead["originalBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Int(stagedRead["modifiedBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertTrue(changeDiagnostics.contains {
            $0["event"] as? String == "workspace.file.read.failed" && $0["path"] as? String == "stale.txt"
        })
        let serializedChangeDiagnostics = String(data: try JSONSerialization.data(withJSONObject: changeDiagnostics), encoding: .utf8) ?? ""
        XCTAssertFalse(serializedChangeDiagnostics.contains("Shared index version."))

        let uiDiffReadCountBeforeClick = try diagnosticEvents().filter {
            $0["event"] as? String == "workspace.file.read.succeeded"
                && $0["path"] as? String == "shared.txt"
                && $0["group"] as? String == "staged"
        }.count
        element("workspace-change-staged-shared.txt").click()
        XCTAssertTrue(element("workspace-diff-overlay").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil({
            guard let events = try? self.diagnosticEvents() else { return false }
            return events.filter {
                $0["event"] as? String == "workspace.file.read.succeeded"
                    && $0["path"] as? String == "shared.txt"
                    && $0["group"] as? String == "staged"
            }.count > uiDiffReadCountBeforeClick
        }, timeout: 10), "Opening the visible file diff should record a new successful workspace file read.")
        assertText("workspace-diff-title", equals: "shared.txt")
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Staged")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        attachScreenshot(named: "Monaco staged diff overlays the task conversation")

        element("workspace-change-working-shared.txt").click()
        assertText("workspace-diff-source", equals: "suggested-parent/changes · Working tree")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")

        element("workspace-change-working-untracked.txt").click()
        assertText("workspace-diff-title", equals: "untracked.txt")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")

        element("workspace-change-working-syntax.json").click()
        assertText("workspace-diff-title", equals: "syntax.json")
        assertText("workspace-diff-editor-status", equals: "Side-by-side")
        assertText("workspace-diff-highlight-status", equals: "1 change highlighted")
        attachScreenshot(named: "Monaco JSON diff uses the local JSON language worker")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("workspace-diff-overlay").waitForExistence(timeout: 2))
        XCTAssertTrue(element("empty-conversation").exists, "Closing the diff should reveal the conversation again.")
        attachScreenshot(named: "Conversation returns after closing the Monaco diff")
    }

    // case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | External file edits and Git commits update the open task's changes sidebar automatically, and fresh CLI connections report the same Git status.
    func test_external_git_edits_and_commit_refresh_workspace_changes() throws {
        let repository = runDirectory.appendingPathComponent("external-git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let trackedFile = repository.appendingPathComponent("tracked.txt")
        try "Baseline.\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(repository, "init", "--initial-branch=main")
        try runGit(repository, "config", "user.name", "StationAI UI Test")
        try runGit(repository, "config", "user.email", "stationai-ui-test@example.invalid")
        try runGit(repository, "add", "tracked.txt")
        try runGit(repository, "commit", "-m", "Baseline")

        let created = try runCLI(["task", "create", "--title", "External Git", "--root", repository.path])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "External Git")
        XCTAssertTrue(element("workspace-changes-empty").waitForExistence(timeout: 10))

        try "Edited externally.\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("workspace-change-working-tracked.txt").waitForExistence(timeout: 10))
        let working = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((working?["working"] as? [[String: Any]])?.map { $0["path"] as? String }, ["tracked.txt"])

        try runGit(repository, "add", "tracked.txt")
        XCTAssertTrue(element("workspace-change-staged-tracked.txt").waitForExistence(timeout: 10))
        try runGit(repository, "commit", "-m", "External commit")
        XCTAssertTrue(element("workspace-changes-empty").waitForExistence(timeout: 10))
        let clean = try runCLI(["task", "changes", "list", taskID])["result"] as? [String: Any]
        XCTAssertEqual((clean?["staged"] as? [Any])?.count, 0)
        XCTAssertEqual((clean?["working"] as? [Any])?.count, 0)
        attachScreenshot(named: "External Git commit clears the open changes sidebar")
    }

    private func launchApp(defaultParent: String?) {
        clearSavedWindowFrames()
        app = XCUIApplication()
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        app.launchEnvironment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        app.launchEnvironment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = defaultParent ?? "__unset__"
        if let codexFixtureExecutable {
            app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        }
        app.launch()
        app.activate()
        waitForBoardOrAbortSuite()
    }

    private func waitForBoardOrAbortSuite() {
        let boardTitle = element("board-title")
        if waitUntil({ self.isStationAIFrontmost }, timeout: 3),
           boardTitle.waitForExistence(timeout: 6) {
            return
        }

        let relaunchedAfterMissingWindow: Bool
        if terminateAppAndWait(app, timeout: 8) {
            app.launch()
            app.activate()
            relaunchedAfterMissingWindow = boardTitle.waitForExistence(timeout: 8)
        } else {
            relaunchedAfterMissingWindow = false
        }

        let expectedBundleID = Bundle(url: appBundle)?.bundleIdentifier ?? "unknown"
        let frontmostDescription = Self.frontmostApplicationDescription
        guard !relaunchedAfterMissingWindow else { return }
        let reason = "StationAI UI startup failed after a process restart recovery attempt. Expected frontmost app \(expectedBundleID); actual frontmost app: \(frontmostDescription); app state: \(app.state.rawValue); board title not found."
        Self.suiteAbortReason = reason
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "StationAI startup failure and frontmost app"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTFail(reason)
    }

    private var isStationAIFrontmost: Bool {
        guard let expectedBundleID = Bundle(url: appBundle)?.bundleIdentifier else { return false }
        return app.state == .runningForeground &&
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleID
    }

    private static var frontmostApplicationDescription: String {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return "none" }
        return "\(frontmost.localizedName ?? "unknown") (\(frontmost.bundleIdentifier ?? "unknown"))"
    }

    private func clearSavedWindowFrames() {
        guard let bundleIdentifier = Bundle(url: appBundle)?.bundleIdentifier,
              bundleIdentifier == "com.stationai.app.e2e" || bundleIdentifier.hasPrefix("com.stationai.app.e2e.") ||
                (bundleIdentifier.hasPrefix("com.stationai.app.worktree.") && bundleIdentifier.contains(".e2e.")),
              let appDefaults = UserDefaults(suiteName: bundleIdentifier) else {
            return
        }
        let windowFrameKeys = appDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSWindow Frame ") }
        for key in windowFrameKeys {
            appDefaults.removeObject(forKey: key)
        }
        appDefaults.synchronize()
    }

    private func makeCodexFixture(emptyQuestions: Bool, nonblocking: Bool = false) throws -> URL {
        let executable = WorkspaceFixture.root
            .appendingPathComponent(emptyQuestions ? "codex-fixture-empty" : (nonblocking ? "codex-fixture-nonblocking" : "codex-fixture-ui"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "The prepared Codex fixture is missing or not executable.")
        return executable
    }

    private func relaunchApp() {
        XCTAssertTrue(terminateAppAndWait(app), "StationAI must stop before the resume-path relaunch.")
        app.launch()
        app.activate()
        waitForBoardOrAbortSuite()
    }

    private func terminateAppAndWait(_ target: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        guard target.state != .notRunning else {
            return true
        }
        target.terminate()
        return waitUntil({ target.state == .notRunning }, timeout: timeout)
    }

    private func openNewTaskConversation() {
        app.activate()
        element("new-task-button").click()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10), "New Task should create and open an empty conversation.")
        XCTAssertTrue(element("conversation-repository-search").waitForExistence(timeout: 10), "A new conversation should open its repository picker.")
        XCTAssertFalse(element("create-task-button").exists, "Direct creation should not show the New Task sheet.")
    }

    private func closeConversationRepositoryPicker() {
        guard element("conversation-repository-search").exists else { return }
        element("add-conversation-repository-button").click()
        XCTAssertTrue(waitUntil({ !self.element("conversation-repository-search").exists }, timeout: 5), "The conversation repository picker should close.")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func createTaskFixture(title: String, roots: [String]) throws {
        var arguments = ["task", "create", "--title", title]
        for root in roots { arguments += ["--root", root] }
        let result = try runCLI(arguments)["result"] as? [String: Any]
        XCTAssertEqual(result?["title"] as? String, title)
    }

    private func saveNewTaskPromptAndReturnToBoard(_ title: String, prompt: String? = nil) {
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 15), "The direct-created task should expose its conversation composer.")
        composer.click()
        composer.typeText(prompt ?? title)
        element("save-task-prompt-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10), "Saving the task prompt should return to the board.")
        guard let task = try? tasksFromBoardList().first, let taskID = task["id"] as? String else {
            XCTFail("The created task should remain in Backlog after saving its prompt.")
            return
        }
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID)?["title"] as? String) ?? nil) != "Generating title…"
        }, timeout: 20), "The generated task title should resolve before the test continues.")
        _ = try? runCLI(["task", "rename", taskID, "--title", title])
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 10), "The created task should be visible with its test title.")
    }

    private func chooseRepositorySuggestion(_ name: String) {
        var searchField = element("conversation-repository-search")
        if !searchField.exists {
            element("add-conversation-repository-button").click()
            searchField = element("conversation-repository-search")
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "The conversation picker should be open before choosing a repository.")
        replaceText(searchField, with: name)
        let suggestion = element("conversation-repository-suggestion-\(name)")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "No repository suggestion for \(name).")
        XCTAssertTrue(suggestion.isHittable, "Repository suggestion \(name) should be reachable in the scrolling picker.")
        suggestion.click()
        XCTAssertTrue(element("conversation-repository-badge-\(name)").waitForExistence(timeout: 10), "The selected repository should appear in the conversation header.")
    }

    private func setConversationRepositoryField(_ repositoryName: String, field: String, value: String) {
        let badge = element("conversation-repository-badge-\(repositoryName)")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "The conversation should show \(repositoryName) before editing its settings.")
        badge.click()
        let edit = element("conversation-repository-\(field)-edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "The conversation repository settings should expose the \(field) edit control.")
        edit.click()
        let fieldElement = element("conversation-repository-\(field)")
        XCTAssertTrue(fieldElement.waitForExistence(timeout: 5))
        replaceText(fieldElement, with: value)
        element("save-conversation-repository-button").click()
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
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func openTask(named title: String) {
        let card = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Task card is missing: \(title)")
        card.click()
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
    }

    private func completeCurrentTaskWithFixtureAnswers(taskTitle: String) throws {
        element("message-composer").click()
        element("message-composer").typeText("Complete this task.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertEqual(try taskRecord(named: taskTitle)?["status"] as? String, "Review")
    }

    private func assertTaskVisible(_ title: String, inColumn status: String) {
        let column = element("column-\(status.lowercased().replacingOccurrences(of: " ", with: "-"))")
        XCTAssertTrue(column.waitForExistence(timeout: 5), "Missing \(status) column.")
        XCTAssertTrue(column.buttons[title].waitForExistence(timeout: 8), "\(title) is not in \(status).")
    }

    private func assertTaskArchived(_ title: String) throws {
        let taskID = try taskID(named: title)
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitForExistence(timeout: 10), "\(title) should appear in the completed task archive.")
        element("close-done-archive-button").click()
    }

    private func moveTaskToDone(_ title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        dragTaskToDone(card)
        XCTAssertTrue(waitUntil({
            do { return try taskRecord(named: title)?["status"] as? String == "Done" }
            catch { return false }
        }, timeout: 15), "Dropping \(title) on the Done target should persist its Done status.")
    }

    private func moveTaskToDone(taskID: String) {
        let card = element("task-card-\(taskID)")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The reviewed task card should remain available by its stable task identifier.")
        dragTaskToDone(card)
        XCTAssertTrue(waitUntil({
            do { return try taskRecord(id: taskID)?["status"] as? String == "Done" }
            catch { return false }
        }, timeout: 15), "Dropping task \(taskID) on the Done target should persist its Done status.")
    }

    private func dragTaskToDone(_ card: XCUIElement) {
        let board = element("board-columns-scroll-view")
        XCTAssertTrue(board.waitForExistence(timeout: 5), "The board columns should remain visible while moving a task to Done.")
        let source = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let doneTarget = board.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.5))
        source.press(forDuration: 0.5, thenDragTo: doneTarget)
    }

    private func assertPixel(_ image: NSImage, normalizedX: CGFloat, normalizedY: CGFloat, rgb expected: (Int, Int, Int), accuracy: Int = 8, file: StaticString = #filePath, line: UInt = #line) {
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

    private func deleteTaskFromContextMenu(_ title: String) {
        let card = app.buttons[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.rightClick()
        let deleteAction = element("delete-task-menu-item")
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "The task context menu should offer Delete Task.")
        deleteAction.click()
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

    private func chooseFile(in panel: XCUIElement, goToSheet: XCUIElement, file: URL) throws {
        let pathField = goToSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(file.deletingLastPathComponent().standardizedFileURL.path)
        pathField.typeKey(.return, modifierFlags: [])
        let target = panel.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@ OR label == %@", file.lastPathComponent, file.lastPathComponent)
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The image picker should show the selected file.")
        target.click()
        let openButton = panel.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        XCTAssertTrue(openButton.isEnabled, "The image file should be selected before opening it.")
        openButton.click()
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

    private func taskRecord(id: String) throws -> [String: Any]? {
        let response = try runCLI(["task", "get", id])
        return response["result"] as? [String: Any]
    }

    private func repositoryRecord(taskID: String, repositoryPath: String) throws -> [String: Any]? {
        guard let task = try taskRecord(id: taskID),
              let repositories = task["repositoryWorktrees"] as? [[String: Any]] else { return nil }
        return repositories.first { ($0["repositoryPath"] as? String) == repositoryPath }
    }

    private func waitForRepositoryValue(
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

    private func diagnosticEvents() throws -> [[String: Any]] {
        let log = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        return try log.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func taskID(named title: String) throws -> String {
        let record = try XCTUnwrap(taskRecord(named: title), "No task named \(title) exists in the real store.")
        return try XCTUnwrap(record["id"] as? String)
    }

    private func seedTaskPullRequest(taskID: String, number: Int, url: String) throws {
        let seeder = WorkspaceFixture.root.appendingPathComponent("seed-task-pr-link")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: seeder.path), "The precompiled SwiftData fixture seeder should be executable.")

        let seed = Process()
        seed.executableURL = seeder
        seed.arguments = [dataDirectory.path, taskID, String(number), url]
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seedText = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, "The isolated SwiftData task record should be seeded: \(seedText)")
        XCTAssertTrue(seedText.contains("Seeded linked PR #\(number)"), seedText)
    }

    private func runCLI(
        _ arguments: [String],
        expectedStatus: Int32 = 0,
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        environment.merge(extraEnvironment) { _, override in override }
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

    private func startCLIProcess(
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) throws -> RunningCLIProcess {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        environment.merge(extraEnvironment) { _, override in override }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return RunningCLIProcess(process: process, stdout: stdout, stderr: stderr)
    }

    private func finishCLIProcess(_ running: RunningCLIProcess, expectedStatus: Int32? = 0) throws -> [String: Any] {
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
        return response
    }

    private func startProgressFixtureTurn(
        taskID: String,
        executable: URL
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe, activeMarker: URL, releaseMarker: URL) {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["conversation", "send", taskID, "--message", "Work on this task."]
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        environment["STATIONAI_E2E_CODEX_EXECUTABLE"] = executable.path
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

    private func runGit(_ repository: URL, _ arguments: String...) throws {
        _ = try runGitOutput(repository, arguments)
    }

    private func runGitOutput(_ repository: URL, _ arguments: String...) throws -> String {
        try runGitOutput(repository, arguments)
    }

    private func runGitOutput(_ repository: URL, _ arguments: [String]) throws -> String {
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

    private func assertHelpTag(for element: XCUIElement, equals expected: String) {
        element.hover()
        let helpTag = app.descendants(matching: .helpTag)
            .matching(NSPredicate(format: "label == %@", expected)).firstMatch
        XCTAssertTrue(helpTag.waitForExistence(timeout: 4), "Expected the hovered control to show the help tag ‘\(expected)’." )
    }

    private func assertHoverEmphasis(for element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let before = element.screenshot().image
        element.hover()
        Thread.sleep(forTimeInterval: 0.2)
        let after = element.screenshot().image
        guard let beforeCG = before.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let afterCG = after.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read control screenshots to verify hover emphasis.", file: file, line: line)
            return
        }
        XCTAssertEqual(beforeCG.width, afterCG.width, "Hover must not change the control screenshot width.", file: file, line: line)
        XCTAssertEqual(beforeCG.height, afterCG.height, "Hover must not change the control screenshot height.", file: file, line: line)
        let beforeBitmap = NSBitmapImageRep(cgImage: beforeCG)
        let afterBitmap = NSBitmapImageRep(cgImage: afterCG)
        var changedPixels = 0
        let step = max(1, beforeCG.width / 40)
        for x in stride(from: 0, to: beforeCG.width, by: step) {
            for y in stride(from: 0, to: beforeCG.height, by: step) {
                guard let beforeColor = beforeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let afterColor = afterBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(beforeColor.redComponent - afterColor.redComponent)
                    + abs(beforeColor.greenComponent - afterColor.greenComponent)
                    + abs(beforeColor.blueComponent - afterColor.blueComponent)
                if delta > 0.08 { changedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(changedPixels, 5, "Hovering a PR control should visibly change its appearance.", file: file, line: line)
    }

    private func element(containingAccessibilityText text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text))
            .firstMatch
    }

    private func accessibleLabelOrValue(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return element.value as? String ?? ""
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !element.exists
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
    static let root = URL(fileURLWithPath: "/tmp/stationai-ui-test-fixtures", isDirectory: true)
    static let ownerMarker = ".stationai-bridge-fixture"
    static let ownerContents = "StationAI bridge tests own this deterministic fixture (v1).\n"

    let parent: URL
    let primary: URL
    let secondary: URL
    let alternate: URL
    let alternateParent: URL
    let custom: URL
    let changes: URL
    let missing: URL
    let nested: URL
    let linkedOutside: URL
    let existingWorktree: URL
    let emptyGitRepository: URL

    static func load() throws -> WorkspaceFixture {
        let marker = root.appendingPathComponent(ownerMarker)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8), contents == ownerContents else {
            throw NSError(domain: "StationAIUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The deterministic Git fixtures are missing or not owned by StationAI. Run scripts/test-ui.sh first."
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
            "changes": parent.appendingPathComponent("changes", isDirectory: true),
            "emptyGitRepository": root.appendingPathComponent("empty-git-repo", isDirectory: true),
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
            changes: locations["changes"]!,
            missing: parent.appendingPathComponent("missing", isDirectory: true),
            nested: locations["nested"]!,
            linkedOutside: locations["linkedOutside"]!,
            existingWorktree: root.appendingPathComponent("existing-worktree", isDirectory: true),
            emptyGitRepository: locations["emptyGitRepository"]!
        )
    }

}

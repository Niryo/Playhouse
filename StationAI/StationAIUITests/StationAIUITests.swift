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
    private var launchDefaultParent: String?
    private var launchWindowTitle: String?
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        if let reason = Self.suiteAbortReason {
            throw XCTSkip("Not run because an earlier case hit a global StationAI startup/focus failure: \(reason)")
        }
        continueAfterFailure = false
        codexFixtureExecutable = nil
        launchWindowTitle = nil
        fixture = try WorkspaceFixture.load()
        runDirectory = URL(fileURLWithPath: "/tmp/stationai-ui-test-data", isDirectory: true)
            .appendingPathComponent("StationAIUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(
            to: runDirectory.appendingPathComponent(WorkspaceFixture.ownerMarker),
            atomically: true,
            encoding: .utf8
        )
        dataDirectory = runDirectory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        appBundle = try Self.findAppBundle()
        preferencesSuiteName = "com.stationai.StationAI.E2E.\(UUID().uuidString)"
        UserDefaults(suiteName: preferencesSuiteName)?.removePersistentDomain(forName: preferencesSuiteName)
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

    // case-contract: test_service_reports_bridge_version | StationAI opens one main board window titled with its worktree label, displays the StationAILogo asset, and the bridge reports API version 1.
    func test_service_reports_bridge_version() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertEqual(app.windows.count, 1, "StationAI should open one board window on launch.")
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15), "The StationAI window did not open.")
        let logo = app.images["StationAI logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 5), "The board header should display the transparent StationAI logo.")
        let window = app.windows.firstMatch
        assertStationAILogoArtwork(logo, in: window)
        XCTAssertEqual(app.windows.firstMatch.title, "StationAI — StationAI UI Test Worktree")
        relaunchApp()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 15), "The board should reopen after relaunch.")
        XCTAssertEqual(app.windows.firstMatch.title, "StationAI — StationAI UI Test Worktree")
        let response = try runCLI(["status"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["service"] as? String, "StationAI")
        XCTAssertEqual(result["bridgeVersion"] as? Int, 1)
        attachScreenshot(named: "StationAI board opened with a healthy bridge")
    }

    // case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, test IDs that do not match the current worktree, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    func test_app_override_rejects_incompatible_bundles() throws {
        let root = repositoryRoot.path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Protected store", prompt: "Protected draft")
        XCTAssertTrue(terminateAppAndWait(app))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", root + "/scripts/check-app-launch-contract.py", appBundle.path, root, dataDirectory.path]
        let directGitPaths = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode_26.5.app/Contents/Developer/usr/bin/git"
        ]
        let directGit = try XCTUnwrap(directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) })
        var checkEnvironment = ProcessInfo.processInfo.environment
        checkEnvironment["PATH"] = URL(fileURLWithPath: directGit).deletingLastPathComponent().path + ":" + (checkEnvironment["PATH"] ?? "")
        check.environment = checkEnvironment
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
        let script = repositoryRoot.appendingPathComponent("scripts/app-profile.sh")
        func profile(for worktree: URL) throws -> [String: String] {
            let directGitPaths = [
                "/opt/homebrew/bin/git",
                "/usr/local/bin/git",
                "/Library/Developer/CommandLineTools/usr/bin/git",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
            ]
            let directGitPath = try XCTUnwrap(
                directGitPaths.first { FileManager.default.isExecutableFile(atPath: $0) },
                "UI tests need a direct Git executable."
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, worktree.path]
            var environment = ProcessInfo.processInfo.environment
            let gitDirectory = URL(fileURLWithPath: directGitPath).deletingLastPathComponent().path
            environment["PATH"] = "\(gitDirectory):\(environment["PATH"] ?? "/usr/bin:/bin")"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, "Failed to resolve the worktree app profile: \(String(data: data, encoding: .utf8) ?? "")")
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
        let sourceProfile = try profile(for: repositoryRoot)
        XCTAssertTrue(launchedIdentifier.hasPrefix(try XCTUnwrap(sourceProfile["bundleID"]) + ".e2e."), "The test app must use the actual source checkout's identity, not a repository fixture's identity.")
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
        let diagnostics = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let loggedStorePaths = diagnostics.compactMap { $0["storePath"] as? String }
        XCTAssertTrue(loggedStorePaths.contains(store.path), "The test app's XPC log must name its isolated store.")
        let primaryDataDirectory = try XCTUnwrap(primary["dataDirectory"])
        XCTAssertFalse(loggedStorePaths.contains(where: { $0.hasPrefix(primaryDataDirectory) }), "The test app's log must not route to the primary store.")
    }

    // case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task immediately opens an empty conversation with the repository picker focused and a visible red missing-working-folder warning; sending stays disabled until a working folder is added. A persisted empty-root task shows the same red warning when its conversation is reopened. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
    func test_task_creation_rejects_invalid_title_roots_and_missing_folder() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        XCTAssertTrue(element("empty-conversation").waitForExistence(timeout: 10))
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 10), "New Task should open the repository picker immediately.")
        let composer = element("chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The chat composer should be visible.")
        let missingFolderError = composer.descendants(matching: .any)
            .matching(identifier: "no-working-folders-error").firstMatch
        XCTAssertTrue(missingFolderError.waitForExistence(timeout: 10), "A task without a repository should show its error in red.")
        XCTAssertEqual(missingFolderError.label, "Choose at least one working folder before sending a message.")
        assertContainsRedForeground(in: missingFolderError)
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
        XCTAssertEqual(try tasksFromBoardList().map { $0["id"] as? String }, [emptyRootTaskID])
        relaunchApp()
        openTask(named: "No roots")
        let reopenedComposer = element("chat-composer")
        XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 10), "The reopened task should show its chat composer.")
        let reopenedMissingFolderError = reopenedComposer.descendants(matching: .any)
            .matching(identifier: "no-working-folders-error").firstMatch
        XCTAssertTrue(reopenedMissingFolderError.waitForExistence(timeout: 10), "Opening the saved task should show the missing-folder error in the conversation too.")
        assertContainsRedForeground(in: reopenedMissingFolderError)
        let deletedEmptyRootTask = try XCTUnwrap(
            try runCLI(["task", "delete", emptyRootTaskID])["result"] as? [String: Any]
        )
        XCTAssertEqual(deletedEmptyRootTask["deleted"] as? Bool, true)
        attachScreenshot(named: "Conversation shows the missing working folder warning")
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
        let createdTaskID = try XCTUnwrap(task["id"] as? String)
        let taskCreate = try XCTUnwrap(events.first {
            $0["event"] as? String == "task.create.succeeded" && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(taskCreate["status"] as? String, "Backlog")
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "persistence.write.succeeded"
                && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(events.filter {
            $0["event"] as? String == "workspace.repository.add.succeeded"
                && $0["taskID"] as? String == createdTaskID
        }.count, 2)
        let promptSave = try XCTUnwrap(events.first {
            $0["event"] as? String == "task.prompt.write.succeeded" && $0["taskID"] as? String == createdTaskID
        })
        XCTAssertEqual(promptSave["status"] as? String, "Backlog")
        XCTAssertEqual(promptSave["submitted"] as? String, "false")
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
        openTask(named: taskTitle)
        XCTAssertTrue(element("task-view-title").waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-secondary").exists)
        XCTAssertTrue(element("conversation-repository-badge-primary").exists)
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

    // case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with in-progress timing columns and no submitted-prompt column waits for the store-write lock while CLI/XPC reads concurrently; migration backs up before adding the missing VARCHAR prompt column as nullable with no default and preserves elapsed time at zero. The CLI preserves the task and draft, and the visible app opens the migrated store and preserves the draft through a subsequent restart with duration still zero; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only draft data survives import, and a subsequent edited draft survives restart without reimport.
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
        let legacyColumns = try sqlite("PRAGMA table_info(ZBOARDTASK)", at: legacyStore)
        XCTAssertFalse(legacyColumns.contains("ZPENDINGSUBMITTEDPROMPT"))
        XCTAssertTrue(legacyColumns.contains("ZINPROGRESSSTARTEDAT"))
        XCTAssertTrue(legacyColumns.contains("ZTOTALINPROGRESSSECONDS"))
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
        XCTAssertTrue(pendingRead.process.isRunning)
        try writeBarrier.release()
        let concurrentRead = try finishCLIProcess(pendingRead)
        XCTAssertEqual((concurrentRead["result"] as? [String: Any])?["savedPrompt"] as? String, draft)
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible(title, inColumn: "Backlog")
        let backups = try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("StationAI.store.before-pending-prompt-") && $0.pathExtension == "backup" }
        XCTAssertEqual(backups.count, 1)
        if let backup = backups.first {
            XCTAssertEqual(try sqlite("PRAGMA quick_check", at: backup).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            XCTAssertEqual(try sqlite("SELECT count(*) FROM ZBOARDTASK", at: backup).trimmingCharacters(in: .whitespacesAndNewlines), "1")
            let backupColumns = try sqlite("PRAGMA table_info(ZBOARDTASK)", at: backup)
            XCTAssertFalse(backupColumns.contains("ZPENDINGSUBMITTEDPROMPT"))
            XCTAssertTrue(backupColumns.contains("ZINPROGRESSSTARTEDAT"))
            XCTAssertTrue(backupColumns.contains("ZTOTALINPROGRESSSECONDS"))
        }
        let migratedColumns = try sqlite("PRAGMA table_info(ZBOARDTASK)", at: store)
        XCTAssertTrue(migratedColumns.contains("ZPENDINGSUBMITTEDPROMPT"))
        XCTAssertTrue(migratedColumns.contains("ZINPROGRESSSTARTEDAT"))
        XCTAssertTrue(migratedColumns.contains("ZTOTALINPROGRESSSECONDS"))
        let migratedColumnRows = migratedColumns
            .split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        let promptColumn = try XCTUnwrap(migratedColumnRows.first { $0.count >= 6 && $0[1] == "ZPENDINGSUBMITTEDPROMPT" })
        XCTAssertEqual(promptColumn[2], "VARCHAR")
        XCTAssertEqual(promptColumn[3], "0")
        XCTAssertEqual(promptColumn[4], "")
        let durationColumn = try XCTUnwrap(
            migratedColumnRows.first { $0.count >= 6 && $0[1] == "ZTOTALINPROGRESSSECONDS" }
        )
        XCTAssertEqual(durationColumn[2], "FLOAT")
        XCTAssertEqual(durationColumn[3], "0")
        XCTAssertEqual(durationColumn[4], "")
        XCTAssertEqual(try sqlite("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK", at: store).trimmingCharacters(in: .whitespacesAndNewlines), "0")
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
        XCTAssertEqual(try sqlite("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK", at: store).trimmingCharacters(in: .whitespacesAndNewlines), "0")
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

    // case-contract: test_task_store_serializes_cross_process_writes | If another process holds the shared task-store write lock when a Codex turn completes after an explicit completed outcome, final status persistence waits and then saves Review status and full history across fresh CLI/XPC reads. Correlated persistence diagnostics include task ID, store path, lock wait, attempts, and retry count; task reads correlate started and completed events by read ID and store path, while failed reads include store file and sidecar state. Reopening the conversation in the UI shows the saved exchange without a store error.
    func test_task_store_serializes_cross_process_writes() throws {
        let fixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-store-write-success-wait")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixtureExecutable.path))
        let ready = URL(fileURLWithPath: fixtureExecutable.path + ".resolve-ready")
        let continuation = URL(fileURLWithPath: fixtureExecutable.path + ".resolve-continue")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: continuation)

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
        var barrier: TaskStoreWriteLockBarrier?
        var barrierReleased = false
        defer {
            if !barrierReleased { try? barrier?.release() }
            if process.process.isRunning {
                process.process.terminate()
                process.process.waitUntilExit()
            }
        }

        let fixturePaused = waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 25)
        let fixtureDiagnostics = (try? diagnosticEvents().filter { ($0["event"] as? String)?.hasPrefix("codex.") == true }) ?? []
        var cliFailureDetails = "CLI still running"
        if !process.process.isRunning {
            let output = String(data: process.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: process.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            cliFailureDetails = "exit=\(process.process.terminationStatus), stdout=\(output), stderr=\(errorOutput)"
        }
        XCTAssertTrue(fixturePaused, "The app-server fixture should pause during the active Codex turn. CLI: \(cliFailureDetails); Codex diagnostics: \(fixtureDiagnostics.suffix(12))")
        let outcome = try runCLI(["task", "outcome", taskID, "completed"])
        XCTAssertEqual((outcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
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

    // case-contract: test_task_done_preserves_worktree_and_branch | Sending the first message derives an auto branch from the generated task title. Every linked PR must be merged before the task can move to Done. App focus checks each linked PR no more than once per 10 seconds; rapid focus changes are suppressed. An unmerged PR keeps its link and suppresses the completion button. PR links and the green completion button have hit targets of at least 30×30 points. After all PRs merge, a later focus check replaces their links with a green completion button, whose click waits for the task lock, rechecks merge state, and moves the task to Done. Completion preserves the source branch and worktree without merging into the local target, retains conversation history, and exposes the task in the searchable read-only archive; the CLI searches matching local Codex JSONL session files, including current input_text and output_text message content, without loading conversation histories, while the visible archive searches both user input_text and assistant output_text, loads the newest 40 first, and reveals older tasks as the user scrolls.
    func test_task_done_preserves_worktree_and_branch() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture()
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        XCTAssertTrue(element("message-composer").waitForExistence(timeout: 10), "New Task should open the composer in its conversation.")
        let task = try XCTUnwrap(tasksFromBoardList().first)
        let record = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first)
        var path = try XCTUnwrap(record["worktreePath"] as? String)
        var branch = try XCTUnwrap(record["branch"] as? String)
        let taskID = try XCTUnwrap(task["id"] as? String)
        _ = try runCLI(["task", "repository", "add-batch", taskID, "--repo", fixture.secondary.path])
        XCTAssertEqual((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(branch, "auto")
        XCTAssertEqual(record["isPending"] as? Bool, true)
        XCTAssertEqual(path, fixture.primary.path)
        let taskPrompt = "Please update the README and add concise setup steps for first time contributors tomorrow."
        let generatedBranch = "generated-fixture-title"
        XCTAssertEqual(record["mergeTarget"] as? String, "main")
        let composer = element("message-composer")
        let composerIsAvailable = waitUntil({ composer.isEnabled && composer.isHittable }, timeout: 15)
        if !composerIsAvailable {
            attachScreenshot(named: "Unavailable composer after repository selection")
        }
        XCTAssertTrue(composerIsAvailable, "The composer should become available after conversation history loads. enabled=\(composer.isEnabled), value=\(composer.value as? String ?? "<none>"), hittable=\(composer.isHittable), frame=\(composer.frame); \(app.debugDescription)")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Untitled task", prompt: taskPrompt)
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
        XCTAssertTrue(terminateAppAndWait(app), "Close StationAI before seeding the real SwiftData fixture.")
        try seedTaskPullRequest(
            taskID: taskID,
            number: 123,
            url: "https://github.com/stationai-test/fixture/pull/123"
        )
        try seedTaskPullRequest(
            taskID: taskID,
            number: 456,
            url: "https://github.com/stationai-test/fixture/pull/456",
            repositoryIndex: 1
        )
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let prLink = element("task-pr-link-\(taskID)-123")
        let secondPRLink = element("task-pr-link-\(taskID)-456")
        XCTAssertTrue(prLink.waitForExistence(timeout: 10), "The linked unmerged PR should remain available on the Review card.")
        XCTAssertTrue(secondPRLink.waitForExistence(timeout: 10), "The task's second linked PR should also be visible.")
        XCTAssertGreaterThanOrEqual(prLink.frame.width, 30, "A PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(prLink.frame.height, 30, "A PR link should have a comfortable vertical hit target.")
        XCTAssertGreaterThanOrEqual(secondPRLink.frame.width, 30, "The second PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(secondPRLink.frame.height, 30, "The second PR link should have a comfortable vertical hit target.")
        let completionButton = element("task-complete-merged-pr-\(taskID)")
        XCTAssertFalse(completionButton.exists)
        let ghCallsURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["STATIONAI_E2E_GH_CALL_LOG"]))
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= 2
        }, timeout: 10), "Opening the board should check the linked PR.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertTrue(prLink.exists, "An unmerged PR should stay as a link.")
        XCTAssertTrue(secondPRLink.exists, "A second unmerged PR should stay as a link.")
        Thread.sleep(forTimeInterval: 10.1)
        let ghStateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["STATIONAI_E2E_GH_STATE_PATH"]))
        try "123=merged\n456=unmerged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        let previousCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= previousCheckCount + 2
        }, timeout: 10), "Regaining focus should refresh the PR merge state.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertFalse(completionButton.exists, "The task should remain incomplete while any linked PR is unmerged.")
        XCTAssertTrue(prLink.exists)
        XCTAssertTrue(secondPRLink.exists)
        let rapidFocusCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual((try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count, rapidFocusCheckCount, "Rapid focus changes should not repeat GitHub checks.")
        Thread.sleep(forTimeInterval: 10.1)
        try "123=unmerged\n456=merged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        let thirdCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= thirdCheckCount + 2
        }, timeout: 10), "Focus should query both PRs when the second PR is already merged.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertFalse(completionButton.exists, "Either unmerged PR should suppress task completion.")
        XCTAssertTrue(prLink.exists)
        XCTAssertTrue(secondPRLink.exists)
        Thread.sleep(forTimeInterval: 10.1)
        try "123=merged\n456=merged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        let fourthCheckCount = (try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline)).count
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({
            ((try? String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) ?? 0) >= fourthCheckCount + 2
        }, timeout: 10), "Regaining focus should refresh both PR merge states.")
        XCTAssertEqual(Set(try String(contentsOf: ghCallsURL, encoding: .utf8).split(whereSeparator: \.isNewline).suffix(2)), Set(["123", "456"]))
        XCTAssertTrue(completionButton.waitForExistence(timeout: 10), "A merged PR should replace its link with the completion button.")
        XCTAssertGreaterThanOrEqual(completionButton.frame.width, 30, "The completion action should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(completionButton.frame.height, 30, "The completion action should have a comfortable vertical hit target.")
        XCTAssertEqual(completionButton.label, "Green checkmark. Complete task, all linked pull requests merged")
        assertContainsGreenForeground(in: completionButton)
        XCTAssertFalse(prLink.exists)
        XCTAssertFalse(secondPRLink.exists)
        let moveLock = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: taskID)
        var moveLockReleased = false
        defer { if !moveLockReleased { try? moveLock.release() } }
        let taskCard = element("task-card-\(taskID)")
        XCTAssertTrue(taskCard.waitForExistence(timeout: 5))
        completionButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "The UI move should wait while another process owns the task operation lock.")
        try "123=merged\n456=unmerged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        try moveLock.release()
        moveLockReleased = true
        XCTAssertTrue(app.buttons["Mark Done Anyway"].waitForExistence(timeout: 10), "Completion should recheck merge state after waiting for the task lock.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        app.buttons["Cancel"].click()
        try "123=merged\n456=merged\n".write(to: ghStateURL, atomically: true, encoding: .utf8)
        completionButton.click()
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

        for index in 1...39 {
            let filler = try XCTUnwrap(try runCLI(["task", "create", "--title", "Archive page filler \(index)", "--root", fixture.custom.path])["result"] as? [String: Any])
            let fillerID = try XCTUnwrap(filler["id"] as? String)
            _ = try runCLI(
                ["conversation", "send", fillerID, "--message", "Complete this archive fixture.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": try XCTUnwrap(codexFixtureExecutable)]
            )
            XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", fillerID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")
        }
        let titleMatch = try XCTUnwrap(try runCLI(["task", "create", "--title", "fixture-secret title match", "--root", fixture.custom.path])["result"] as? [String: Any])
        let titleMatchID = try XCTUnwrap(titleMatch["id"] as? String)
        let fixtureExecutable = try XCTUnwrap(codexFixtureExecutable)
        _ = try runCLI(
            ["conversation", "send", titleMatchID, "--message", "Another completed conversation.", "--answer", "color=Blue", "--answer", "token=fixture-secret"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureExecutable]
        )
        XCTAssertEqual(try XCTUnwrap((try runCLI(["task", "move", titleMatchID, "Done"])["result"] as? [String: Any])?["status"] as? String), "Done")

        let threadID = try XCTUnwrap(taskRecord(id: taskID)?["codexThreadID"] as? String)
        let sessions = dataDirectory.appendingPathComponent("codex-home/sessions/2026/10/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionFile = sessions.appendingPathComponent("rollout-2026-10-22T00-00-00-\(threadID).jsonl")
        let sessionLines: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "LOCAL-SESSION-ONLY-input-token"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "LOCAL-SESSION-ONLY-output-token"]]]]
        ]
        let sessionData = try sessionLines.map { try JSONSerialization.data(withJSONObject: $0) + Data([0x0A]) }.reduce(into: Data()) { $0.append($1) }
        try sessionData.write(to: sessionFile, options: .atomic)

        let archiveButton = element("done-archive-button")
        archiveButton.click()
        let archiveResult = element("done-archive-task-\(taskID)")
        XCTAssertTrue(element("done-archive-task-\(titleMatchID)").waitForExistence(timeout: 10), "The newest completed task should appear in the first archive page.")
        let archiveList = app.scrollViews["done-archive-list"]
        XCTAssertEqual(archiveList.value as? String, "40 tasks loaded", "The archive should fetch one 40-task page initially.")
        XCTAssertFalse(archiveResult.exists, "Older tasks should not be loaded into the first archive page.")
        for _ in 0..<8 where !archiveResult.isHittable { archiveList.swipeUp() }
        XCTAssertTrue(waitUntil({ archiveResult.isHittable && archiveList.frame.intersects(archiveResult.frame) }, timeout: 10), "Scrolling should load older completed tasks into the archive viewport.")
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
        element("clear-archive-search-button").click()
        archiveSearch.typeText("local-session-only-output-TOKEN")
        XCTAssertTrue(waitUntil({ archiveResult.exists && !titleMatchResult.exists }, timeout: 10), "Searching assistant output_text should show its conversation match and filter out unrelated title matches.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("local-session-only-input-TOKEN")
        XCTAssertTrue(waitUntil({ archiveResult.exists && !titleMatchResult.exists }, timeout: 10), "Searching user input_text should show its conversation match and filter out unrelated title matches.")
        element("clear-archive-search-button").click()
        archiveSearch.typeText("FiXtUrE-SeCrEt")
        XCTAssertTrue(titleMatchResult.waitForExistence(timeout: 10))
        XCTAssertTrue(archiveResult.waitForExistence(timeout: 10))
        archiveResult.click()
        XCTAssertTrue(element("archived-conversation-read-only").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertFalse(element("message-composer").exists, "Archived conversations must not expose the composer.")
        XCTAssertFalse(element("edit-workspace-roots-button").isEnabled, "Archived conversations must not allow workspace edits.")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Done", "Leaving the read-only conversation must not alter the archived task.")
        attachScreenshot(named: "Completed task opens from the searchable read-only archive")
    }

    // case-contract: test_review_pr_conflicts_probe_and_verify | Separate Review task cards probe their linked pull requests concurrently on app focus, with refreshes limited to one per 10 seconds. A conflicting PR or a mergeable PR whose remote head is not pushed locally retains the imported conflict action with its indicator artwork beside its PR link; the UI renders the artwork inside the action, keeps it beside the PR link, and gives both controls hit targets of at least 30×30 points. Clicking the conflict action sends the corrected request in the task conversation. CLI and UI use the same GitHub mergeability and head checks, retry once when resolution remains unconfirmed, and clear the action only after GitHub confirms the pushed head.
    func test_review_pr_conflicts_probe_and_verify() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        var ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [123, 456])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Review PR conflict UI", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Review PR conflict UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review PR conflict UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(taskID)").exists }, timeout: 10))
        let secondCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Second Review PR conflict UI", "--repo", fixture.secondary.path,
            "--merge-target", "\(fixture.secondary.path)=main",
        ])["result"] as? [String: Any])
        let secondTaskID = try XCTUnwrap(secondCreated["id"] as? String)
        openTask(named: "Second Review PR conflict UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Second Review PR conflict UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(secondTaskID)").exists }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/stationai-test/fixture/pull/123")
        try seedTaskPullRequest(taskID: secondTaskID, number: 456, url: "https://github.com/stationai-test/fixture/pull/456")
        let remote = runDirectory.appendingPathComponent("conflict-solver-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should use a fresh owned bare remote.")
        _ = try runGitOutput(remote, "init", "--bare")
        for (id, number) in [(taskID, 123), (secondTaskID, 456)] {
            let record = try XCTUnwrap((try taskRecord(id: id)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
            try runGit(worktree, "push", remote.path, "HEAD:refs/heads/pr-\(number)")
        }
        ghEnvironment["STATIONAI_E2E_GH_REMOTE_REPOSITORY"] = remote.path

        let resolutionFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-success-wait")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolutionFixture.path))
        codexFixtureExecutable = resolutionFixture.path
        let readyURL = URL(fileURLWithPath: resolutionFixture.path + ".resolve-ready")
        let continueURL = URL(fileURLWithPath: resolutionFixture.path + ".resolve-continue")
        let startCountURL = URL(fileURLWithPath: resolutionFixture.path + ".resolve-start-count")
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: continueURL)
        try? FileManager.default.removeItem(at: startCountURL)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        let link = element("task-pr-link-\(taskID)-123")
        let resolveButton = element("task-resolve-pr-conflicts-\(taskID)")
        let resolveIcon = app.images["task-resolve-pr-conflicts-icon-\(taskID)"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let secondLink = element("task-pr-link-\(secondTaskID)-456")
        XCTAssertTrue(secondLink.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(secondLink.frame.width, 30, "The second task's PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(secondLink.frame.height, 30, "The second task's PR link should have a comfortable vertical hit target.")
        let startedDirectory = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["STATIONAI_E2E_GH_STARTED_DIRECTORY"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("456").path), "Both Review task probes should overlap on focus.")
        XCTAssertFalse(resolveButton.exists, "A mergeable PR should not show the conflict action.")
        Thread.sleep(forTimeInterval: 10.1)
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["STATIONAI_E2E_GH_STATE_PATH"]))
        try "123=conflicting\n".write(to: stateURL, atomically: true, encoding: .utf8)
        for number in [123, 456] { try? FileManager.default.removeItem(at: startedDirectory.appendingPathComponent("\(number)")) }
        activateOtherAppThenReturn()
        XCTAssertTrue(resolveButton.waitForExistence(timeout: 10), "Focus should discover the conflicting PR.")
        XCTAssertGreaterThanOrEqual(resolveButton.frame.width, 30, "The conflict action should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(resolveButton.frame.height, 30, "The conflict action should have a comfortable vertical hit target.")
        XCTAssertGreaterThanOrEqual(link.frame.width, 30, "A PR link should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(link.frame.height, 30, "A PR link should have a comfortable vertical hit target.")
        XCTAssertTrue(resolveIcon.waitForExistence(timeout: 5), "The imported conflict indicator artwork should render inside the action.")
        XCTAssertTrue(resolveButton.frame.contains(resolveIcon.frame), "The conflict indicator artwork should be inside the action button.")
        XCTAssertLessThanOrEqual(resolveButton.frame.maxX, link.frame.minX + 1, "The conflict action should sit beside its PR link.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("123").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedDirectory.appendingPathComponent("456").path), "Focus refresh should probe separate Review cards concurrently.")

        resolveButton.click()
        let initialPrompt = "The PR has conflicts. Fix them, commit, and push."
        let initialPromptElement = app.staticTexts.matching(NSPredicate(format: "label == %@", initialPrompt)).firstMatch
        XCTAssertTrue(initialPromptElement.waitForExistence(timeout: 10), "The conflict action should send the corrected instruction into the task conversation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: readyURL.path) }, timeout: 10), "Codex should start the conflict resolution turn.")
        try "Continue after first conflict attempt.\n".write(to: continueURL, atomically: true, encoding: .utf8)

        let retryPrompt = "The PR still has conflicts or your latest commit has not reached GitHub. Resolve the remaining conflicts, commit, and push. Verify the PR's merge status before finishing."
        let retryPromptElement = app.staticTexts.matching(NSPredicate(format: "label == %@", retryPrompt)).firstMatch
        XCTAssertTrue(retryPromptElement.waitForExistence(timeout: 15), "A still-conflicting PR should receive one follow-up turn.")
        XCTAssertTrue(waitUntil({
            (try? String(contentsOf: startCountURL, encoding: .utf8).split(whereSeparator: \.isNewline).count) == 2
        }, timeout: 10), "Codex should start exactly two resolution turns.")
        let primaryRecord = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let primaryWorktree = URL(fileURLWithPath: try XCTUnwrap(primaryRecord["worktreePath"] as? String), isDirectory: true)
        try "Resolution from the conflict solver.\n".write(
            to: primaryWorktree.appendingPathComponent("conflict-solver-resolution.txt"), atomically: true, encoding: .utf8
        )
        try runGit(primaryWorktree, "add", "conflict-solver-resolution.txt")
        try runGit(primaryWorktree, "commit", "-m", "Resolve pull request conflicts")
        let resolvedLocalHead = try runGitOutput(primaryWorktree, "rev-parse", "HEAD")
        let staleRemoteHead = try runGitOutput(remote, "rev-parse", "refs/heads/pr-123")
        XCTAssertNotEqual(resolvedLocalHead, staleRemoteHead, "A local resolution commit must remain unconfirmed until it is pushed.")
        try "123=remote\n456=unmerged\n".write(to: stateURL, atomically: true, encoding: .utf8)
        _ = try runCLI(
            ["task", "outcome", taskID, "completed"],
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": resolutionFixture.path]
        )
        try "Continue after verified conflict resolution.\n".write(to: continueURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ element("send-message-button").exists }, timeout: 15), "The second Codex turn should finish after the verified push.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        element("back-to-board-button").click()
        XCTAssertTrue(resolveButton.exists, "A mergeable PR with a mismatched remote head must retain the conflict action.")
        try runGit(primaryWorktree, "push", remote.path, "HEAD:refs/heads/pr-123")
        XCTAssertEqual(try runGitOutput(remote, "rev-parse", "refs/heads/pr-123"), resolvedLocalHead)
        try "123=remote\n456=unmerged\n".write(to: stateURL, atomically: true, encoding: .utf8)
        for number in [123, 456] { try? FileManager.default.removeItem(at: startedDirectory.appendingPathComponent("\(number)")) }
        Thread.sleep(forTimeInterval: 10.1)
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({ !resolveButton.exists }, timeout: 10), "The action should disappear after GitHub confirms the pushed head.")
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

    // case-contract: test_task_pr_create_reports_real_gh_failure | The CLI confirms a new repository-backed task persists in Backlog; the UI shows no PR control there, then shows the active-card PR action after the conversation completes with a minimum 30-point hit target. The Done archive control retains its help and waits for the task lock before publication failure without saving a PR link or changing Done status.
    func test_task_pr_create_reports_real_gh_failure() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR failure UI", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["status"] as? String, "Backlog")
        XCTAssertTrue(element("task-card-\(taskID)").waitForExistence(timeout: 5), "The backlog task card should render before checking its PR controls.")
        XCTAssertFalse(element("task-create-pr-\(taskID)").exists, "Backlog cards must not expose a PR action.")
        let createdRecord = try XCTUnwrap((created["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(createdRecord["mergeTarget"] as? String, "main")
        XCTAssertEqual((try runCLI(["task", "pr", "conflicts", taskID])["result"] as? [String: Any])?["repositories"] as? [String], [])
        openTask(named: "PR failure UI")
        element("conversation-repository-badge-primary").click()
        let mergeTargetValue = element("conversation-repository-merge-target-value")
        XCTAssertTrue(mergeTargetValue.waitForExistence(timeout: 5))
        XCTAssertEqual(accessibleLabelOrValue(of: mergeTargetValue), "main")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR failure UI")
        element("back-to-board-button").click()
        let activeCreateButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(activeCreateButton.waitForExistence(timeout: 5), "An active repository task should expose its PR action on the card.")
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.width, 30, "The PR action should have a comfortable horizontal hit target.")
        XCTAssertGreaterThanOrEqual(activeCreateButton.frame.height, 30, "The PR action should have a comfortable vertical hit target.")
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

    // case-contract: test_task_pr_conflicts_detect_without_mutation | The real Git CLI detects conflicts without mutation and blocks PR creation until the explicit Fix Conflicts action is used; it resolves staged conflicts locally without pushing and commits and pushes a staged resolution without changing the target. The paired UI verifies PR creation directs the user to resolve conflicts in the task worktree and leaves unresolved conflicts uncommitted and unpublished.
    func test_task_pr_conflicts_detect_without_mutation() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR conflict choice UI", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        _ = try XCTUnwrap((created["repositoryWorktrees"] as? [[String: Any]])?.first)
        openTask(named: "PR conflict choice UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR conflict choice UI")
        let completedRecord = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(completedRecord["worktreePath"] as? String), isDirectory: true)

        let conflictPath = "stationai-pr-conflict-fixture.txt"
        try "target branch version\n".write(to: fixture.primary.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(fixture.primary, "add", conflictPath)
        try runGit(fixture.primary, "commit", "-m", "Update PR target fixture")
        try "task branch version\n".write(to: worktree.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictPath)
        try runGit(worktree, "commit", "-m", "Update task branch fixture")
        let branchHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        let targetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        let remote = WorkspaceFixture.root.appendingPathComponent("pr-conflict-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should start with an isolated bare remote fixture.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGitOutput(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        try runGit(fixture.primary, "push", "--set-upstream", "origin", "main")
        let conflictResult = try runCLI(["task", "pr", "conflicts", taskID])["result"] as? [String: Any]
        XCTAssertEqual(conflictResult?["repositories"] as? [String], [fixture.primary.path])
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD"), branchHead, "Conflict detection must leave the task branch unchanged.")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead, "Conflict detection must leave the target branch unchanged.")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent(conflictPath), encoding: .utf8), "task branch version\n")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent(conflictPath), encoding: .utf8), "target branch version\n")

        element("back-to-board-button").click()
        let prButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(prButton.waitForExistence(timeout: 5))
        prButton.click()
        let blockedAlert = app.alerts["Couldn't create pull request"]
        XCTAssertTrue(blockedAlert.waitForExistence(timeout: 10), "PR creation should direct the user to resolve conflicts in the task worktree.")
        XCTAssertTrue(blockedAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Resolve conflicts in the task worktree")).firstMatch.exists)
        blockedAlert.buttons["OK"].click()
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD"), branchHead, "Blocked PR creation must leave the task branch unchanged.")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead)
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "ls-remote", "--heads", "origin", try XCTUnwrap(completedRecord["branch"] as? String))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "Blocked PR creation must not publish the task branch."
        )
        XCTAssertTrue(waitUntil({ prButton.isEnabled }, timeout: 10))
        XCTAssertNil((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"])
        let finalRecord = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertNil(finalRecord["pullRequestNumber"])
    }

    // case-contract: test_done_archive_displays_existing_pull_request_link | CLI/XPC fresh reads confirm saved PR data; the UI shows active and archived PR links and an active task's Create PR button. Hovering the outer padded edge of each control triggers its hover feedback.
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
        let createPRButton = element("task-create-pr-\(activeTaskID)")
        XCTAssertTrue(createPRButton.waitForExistence(timeout: 5), "An active repository task should expose its Create PR button.")
        assertHoverEmphasis(for: createPRButton)

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
        element("done-archive-button").click()
        XCTAssertTrue(element("done-archive-task-\(taskID)").waitForExistence(timeout: 10))
        let prLink = app.links["done-archive-pr-link-\(taskID)-123"]
        XCTAssertTrue(prLink.waitForExistence(timeout: 10), "The Done archive should show the saved PR number as a link.")
        assertHoverEmphasis(for: prLink)
        attachScreenshot(named: "Done archive shows the linked pull request")
    }

    // case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    func test_task_lifecycle_rollout_clears_records_and_clean_worktrees() throws {
        let clean = try runCLI(["task", "create", "--title", "Rollout clean", "--repo", fixture.primary.path])
        let dirty = try runCLI(["task", "create", "--title", "Rollout dirty", "--repo", fixture.secondary.path])
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let cleanTaskID = try XCTUnwrap((clean["result"] as? [String: Any])?["id"] as? String)
        let dirtyTaskID = try XCTUnwrap((dirty["result"] as? [String: Any])?["id"] as? String)
        _ = try runCLI(["conversation", "send", cleanTaskID, "--message", "Materialize the clean worktree.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
        _ = try runCLI(["conversation", "send", dirtyTaskID, "--message", "Materialize the dirty worktree.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
        let cleanResult = try XCTUnwrap(try runCLI(["task", "get", cleanTaskID])["result"] as? [String: Any])
        let dirtyResult = try XCTUnwrap(try runCLI(["task", "get", dirtyTaskID])["result"] as? [String: Any])
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

    // case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status; ⌘F reveals and focuses a prominent board search that filters task cards by title as text changes, while close restores all cards. Answering a question without an explicit completed outcome leaves the task in Waiting Response. Task card titles use slightly expanded letter spacing and line spacing.
    func test_task_status_transitions_and_rejects_unknown_status() throws {
        let waitingFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-status-transition-ui")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: waitingFixture.path))
        codexFixtureExecutable = waitingFixture.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Status transitions", roots: [fixture.primary.path])
        try createTaskFixture(title: "Searchable board card", roots: [fixture.alternate.path])
        let titleElement = app.staticTexts["Searchable board card"]
        XCTAssertTrue(titleElement.waitForExistence(timeout: 5), "The task card should expose its rendered title text.")
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let untrackedWidth = ("Searchable board card" as NSString).size(withAttributes: [.font: titleFont]).width
        XCTAssertGreaterThan(
            titleElement.frame.width,
            untrackedWidth + 2,
            "The title's rendered width should reflect the added letter spacing."
        )
        let wrappedTitle = "Task card title spacing increases between wrapped lines"
        try createTaskFixture(title: wrappedTitle, roots: [fixture.alternate.path])
        let wrappedTitleElement = app.staticTexts[wrappedTitle]
        XCTAssertTrue(wrappedTitleElement.waitForExistence(timeout: 5))
        let wrappedTitleBaseline = NSAttributedString(
            string: wrappedTitle,
            attributes: [.font: titleFont, .kern: 0.35]
        ).boundingRect(
            with: CGSize(width: wrappedTitleElement.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        XCTAssertGreaterThan(
            wrappedTitleElement.frame.height,
            wrappedTitleBaseline + 1,
            "Wrapped task titles should have visible spacing between lines."
        )
        XCTAssertFalse(element("board-search-field").exists, "Board search should stay hidden until requested.")
        app.typeKey("f", modifierFlags: .command)
        let boardSearch = element("board-search-field")
        XCTAssertTrue(boardSearch.waitForExistence(timeout: 5), "Command+F should reveal the prominent board search.")
        XCTAssertLessThan(element("board-search-bar").frame.maxY, element("board-columns-scroll-view").frame.minY, "Board search should sit above the task columns.")
        boardSearch.typeText("Searchable")
        XCTAssertTrue(app.buttons["Searchable board card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Status transitions"].exists, "Nonmatching task cards should be filtered out.")
        element("close-board-search-button").click()
        XCTAssertFalse(element("board-search-field").exists)
        XCTAssertTrue(app.buttons["Status transitions"].exists)
        XCTAssertTrue(app.buttons["Searchable board card"].exists)
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
        XCTAssertEqual(try taskRecord(id: waitingTaskID)?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        assertTaskVisible("Waiting layout", inColumn: "Waiting Response")

        try "Release the active turn.\n".write(to: activeTurn.releaseMarker, atomically: true, encoding: .utf8)
        activeTurn.process.waitUntilExit()
        let activeOutput = String(data: activeTurn.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let activeError = String(data: activeTurn.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(activeTurn.process.terminationStatus, 0, "The In Progress fixture turn should complete: \(activeOutput) \(activeError)")
        let activeResponseLine = try XCTUnwrap(activeOutput.split(whereSeparator: \.isNewline).last)
        let activeResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(activeResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(activeResponse["ok"] as? Bool == true)
        XCTAssertEqual(try taskRecord(id: activeTaskID)?["status"] as? String, "Waiting Response")
        assertTaskVisible("In Progress layout", inColumn: "Waiting Response")

        for index in 1...12 {
            try createTaskFixture(title: "Backlog scroll \(index)", roots: [fixture.primary.path])
        }
        let lowestTask = app.buttons["Backlog scroll 1"]
        XCTAssertFalse(lowestTask.isHittable, "The final backlog task should begin below the board viewport.")
        for _ in 0..<20 where !lowestTask.isHittable {
            boardViewport.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(waitUntil({ lowestTask.exists && lowestTask.isHittable }, timeout: 10), "Vertical board scrolling should make lower backlog tasks reachable.")
    }

    // case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; without an outcome call, a successful turn ends in Waiting Response. The board shows progress details and places completed tasks in Review and waiting or omitted outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work. Only an explicit completed outcome reaches Review.
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
        environment["CODEX_HOME"] = dataDirectory.appendingPathComponent("codex-home").path
        environment["STATIONAI_WORKTREE_LABEL"] = "StationAI UI Test Worktree"
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
        let label = element("task-progress-label-\(taskID.uppercased())")
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
        relaunchApp()
        XCTAssertTrue(waitForDisappearance(label), "Clearing a report should remove its secondary row from the card.")
        _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing"])
        relaunchApp()
        let completedOutcome = try runCLI(["task", "outcome", taskID, "completed"])
        let completedOutcomeRecord = try XCTUnwrap(completedOutcome["result"] as? [String: Any])
        XCTAssertEqual(completedOutcomeRecord["outcome"] as? String, "completed")
        XCTAssertEqual(completedOutcomeRecord["taskStatus"] as? String, "In Progress", "Outcome should be applied only after the turn completes.")
        try "Release the active turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "The fixture conversation should finish successfully: \(output) \(errorOutput)")
        let responseLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        XCTAssertTrue(response["ok"] as? Bool == true)
        assertTaskVisible("Progress reports", inColumn: "Review")

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
        let waitingOutcome = try runCLI(["task", "outcome", taskID, "waiting-response"])
        let waitingOutcomeRecord = try XCTUnwrap(waitingOutcome["result"] as? [String: Any])
        XCTAssertEqual(waitingOutcomeRecord["outcome"] as? String, "waiting-response")
        XCTAssertEqual(waitingOutcomeRecord["taskStatus"] as? String, "In Progress")
        try "Release the resumed turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        resumedProcess.waitUntilExit()
        let resumedOutput = String(data: resumedStdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let resumedError = String(data: resumedStderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(resumedProcess.terminationStatus, 0, "The resumed fixture conversation should finish successfully: \(resumedOutput) \(resumedError)")
        let resumedResponseLine = try XCTUnwrap(resumedOutput.split(whereSeparator: \.isNewline).last)
        let resumedResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resumedResponseLine.utf8)) as? [String: Any])
        XCTAssertTrue(resumedResponse["ok"] as? Bool == true)
        assertTaskVisible("Progress reports", inColumn: "Waiting Response")

        let omittedProcess = Process()
        omittedProcess.executableURL = cliURL
        omittedProcess.arguments = ["conversation", "send", taskID, "--message", "A turn without an outcome."]
        omittedProcess.environment = environment
        let omittedStdout = Pipe()
        let omittedStderr = Pipe()
        omittedProcess.standardOutput = omittedStdout
        omittedProcess.standardError = omittedStderr
        try omittedProcess.run()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: activeMarker.path) }, timeout: 10), "The no-outcome turn should resume the existing fixture thread.")
        try "Release the no-outcome turn.\n".write(to: releaseMarker, atomically: true, encoding: .utf8)
        omittedProcess.waitUntilExit()
        let omittedOutput = String(data: omittedStdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let omittedError = String(data: omittedStderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(omittedProcess.terminationStatus, 0, "The no-outcome fixture conversation should finish successfully: \(omittedOutput) \(omittedError)")

        let finished = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(finished["status"] as? String, "Waiting Response", "A resumed turn without an outcome call should default to Waiting Response.")
        assertTaskVisible("Progress reports", inColumn: "Waiting Response")
        XCTAssertNil(finished["progressLabel"], "Turn completion should clear the last live report.")
        XCTAssertTrue(waitForDisappearance(report), "Turn completion should remove the progress row from the board card.")
        let turnData = try Data(contentsOf: URL(fileURLWithPath: executable.path + ".history"))
        let turn = try XCTUnwrap(try JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        let instructions = try XCTUnwrap(turn["threadStartDeveloperInstructions"] as? String)
        XCTAssertTrue(instructions.contains(cliURL.path))
        XCTAssertTrue(instructions.contains("task progress publish"))
        XCTAssertTrue(instructions.contains("hidden from the conversation"))
        XCTAssertTrue(instructions.contains("at least every 30 seconds"))
        XCTAssertTrue(instructions.contains("starting or finishing a substantial tool call"))
        XCTAssertTrue(instructions.contains("active suite/case and position"))
        XCTAssertTrue(instructions.contains("CLI/XPC 3/8"))
        XCTAssertTrue(instructions.contains("under 80 characters"))
        XCTAssertTrue(instructions.contains("task outcome"))
        XCTAssertTrue(instructions.contains("waiting-response"))
        XCTAssertTrue(instructions.contains("final CLI action"))
        XCTAssertEqual(turn["threadStartCount"] as? Int, 1, "The follow-up should reuse the thread created with progress instructions.")
        XCTAssertGreaterThanOrEqual(turn["threadResumeCount"] as? Int ?? 0, 1)
        let turns = try XCTUnwrap(turn["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 3)
        XCTAssertTrue(turns.allSatisfy { $0["developerInstructions"] == nil || $0["developerInstructions"] is NSNull }, "Thread-scoped task instructions should not be repeated in turn requests.")
        let resumeInstructions = try XCTUnwrap(turn["threadResumeDeveloperInstructions"] as? [Any])
        XCTAssertFalse(resumeInstructions.isEmpty, "Resumed task threads should receive updated task instructions.")
        XCTAssertTrue(resumeInstructions.allSatisfy { ($0 as? String)?.contains("task outcome") == true })
    }

    // case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; a staged completed outcome is discarded if its turn fails, leaving the task Blocked. The task card removes the report while lifecycle states remain Blocked or Waiting Response, and answering the question resumes the task successfully.
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
            let staged = try runCLI(["task", "outcome", taskID, "completed"])
            XCTAssertEqual((staged["result"] as? [String: Any])?["outcome"] as? String, "completed")
            XCTAssertEqual((staged["result"] as? [String: Any])?["taskStatus"] as? String, "In Progress")
            let report = element("task-progress-report-\(taskID.uppercased())")
            let label = element("task-progress-label-\(taskID.uppercased())")
            _ = try runCLI(["task", "progress", "publish", taskID, "--type", "testing", "--detail", "Waiting for the result"])
            XCTAssertEqual(try taskRecord(id: taskID)?["progressLabel"] as? String, "Testing")
            relaunchApp()
            XCTAssertTrue(element("task-card-\(taskID.uppercased())").waitForExistence(timeout: 5), "The active task should appear on the board.")
            XCTAssertEqual(try taskRecord(id: taskID)?["progressLabel"] as? String, "Testing", "Progress should remain persisted after the app relaunches.")
            XCTAssertTrue(waitUntil({ label.exists && (label.value as? String)?.contains("Testing") == true }, timeout: 20), "The active task card should show progress before a failed turn. \(app.debugDescription)")
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
            assertTaskVisible(title, inColumn: "Blocked")
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
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5), "The board should reopen after leaving the question.")
        let waitingReportLabel = element("task-progress-label-\(questionTaskID.uppercased())")
        XCTAssertTrue(waitForDisappearance(waitingReportLabel), "The Waiting Response card should not retain the agent's progress row.")
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
            if completedStatus == "Waiting Response" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Waiting Response", "An answered turn without an explicit completion outcome should return to Waiting Response.")
        XCTAssertNil(try taskRecord(id: questionTaskID)?["progressLabel"] as? String)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        assertTaskVisible("Progress question", inColumn: "Waiting Response")
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
        app.activate()
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
        XCTAssertTrue(waitForDisappearance(element("save-conversation-repository-button")), "A successful repository save should close its editor.")
        badge.click()
        app.activate()
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
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: worktreePath) }, timeout: 10), "Removing the clean managed repository should finish deleting its worktree.")
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
        var pendingDeleteEvent: [String: Any]?
        XCTAssertTrue(waitUntil({
            guard let events = try? self.diagnosticEvents() else { return false }
            pendingDeleteEvent = events.first {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == pendingID
            }
            return pendingDeleteEvent != nil
        }, timeout: 5), "Deleting a task through the visible menu should leave a persistent diagnostic event.")
        let pendingDeleteEventValue = try XCTUnwrap(pendingDeleteEvent)
        XCTAssertEqual(pendingDeleteEventValue["taskStatus"] as? String, "Backlog")
        XCTAssertNotNil(pendingDeleteEventValue["processID"] as? String)
        XCTAssertNotNil(pendingDeleteEventValue["storePath"] as? String)
        assertCLIError(try runCLI(["task", "get", pendingID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.secondary.path), "Deleting a pending task must preserve its source repository.")

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

    // case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. Dark and Light appearance choices persist, the removed PR conflict preference is absent from CLI/XPC and Settings, and appearance changes update the open Settings picker.
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
        let parentVisibleToBridge = waitUntil({
            guard let response = try? self.runCLI(["settings", "get"]),
                  let settings = response["result"] as? [String: Any] else { return false }
            return (settings["defaultParentFolder"] as? String) == self.fixture.parent.path
        }, timeout: 5)
        XCTAssertTrue(parentVisibleToBridge, "The selected parent folder should be visible through a fresh CLI/XPC read.")
        let changeSuggestionParent = element("choose-repository-suggestion-parent-button")
        XCTAssertTrue(changeSuggestionParent.waitForExistence(timeout: 5), "The picker should keep a Change parent action available after a valid parent has been selected.")
        XCTAssertTrue(changeSuggestionParent.label.localizedCaseInsensitiveContains("Change"))
        changeSuggestionParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.alternateParent, confirmationButton: "Use This Folder")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitForExistence(timeout: 10), "Changing the parent should refresh the repository suggestions.")
        XCTAssertFalse(element("conversation-repository-suggestion-primary").exists, "Suggestions from the previous parent should be replaced.")
        XCTAssertTrue(waitUntil({
            guard let response = try? self.runCLI(["settings", "get"]),
                  let settings = response["result"] as? [String: Any] else { return false }
            return (settings["defaultParentFolder"] as? String) == self.fixture.alternateParent.path
        }, timeout: 5), "The changed parent folder should be visible through a fresh CLI/XPC read.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
        XCTAssertEqual(try tasksFromBoardList().count, 0, "Backing out should discard the empty pending conversation.")

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 10), "Workspace Settings did not open.")
        let appearancePicker = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "appearance-picker").firstMatch
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 5), "Workspace Settings should expose the Dark and Light theme choices.")
        XCTAssertFalse(preferencesWindow.descendants(matching: .any).matching(identifier: "pr-conflict-action-picker").firstMatch.exists, "Workspace Settings should no longer expose automatic PR conflict behavior.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        appearancePicker.click()
        let lightChoice = preferencesWindow.menuItems["Light"]
        if lightChoice.waitForExistence(timeout: 2) {
            lightChoice.click()
        } else {
            preferencesWindow.buttons["Light"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "light")
        _ = try runCLI(["settings", "set-appearance", "dark"])
        XCTAssertTrue(waitUntil({ appearancePicker.value as? String == "dark" }, timeout: 5), "An external CLI write should update the open appearance picker.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferencesWindow.exists }, timeout: 5), "Settings should close before checking the workspace canvas.")
        let workspaceCanvas = element("board-columns-scroll-view")
        XCTAssertTrue(workspaceCanvas.waitForExistence(timeout: 5), "The board workspace should be visible.")
        assertPixel(workspaceCanvas.screenshot().image, normalizedX: 0.02, normalizedY: 0.5, rgb: (30, 30, 30), accuracy: 20)
        app.typeKey(",", modifierFlags: .command)
        let reopenedPreferences = settingsWindow
        XCTAssertTrue(reopenedPreferences.waitForExistence(timeout: 10), "Workspace Settings did not reopen.")
        let chooseParent = reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "choose-default-parent-folder-button").firstMatch
        XCTAssertTrue(chooseParent.waitForExistence(timeout: 10))
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
        assertCLIError(try runCLI(["task", "get", firstTaskID], expectedStatus: 3), code: "not_found")

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

    // case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, logs task.create.succeeded for its ID, verifies empty history, and deletes it cleanly. New Task logs start and completion events with the same attempt ID and created task ID, then opens one empty conversation with its repository picker focused and no create sheet. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    func test_new_task_has_empty_conversation_history() throws {
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains { $0["event"] as? String == "ui.new_task.started" }) ?? false
        }, timeout: 2), "The New Task start event should reach the diagnostics file promptly after the click.")
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
        let newTaskEvents = try diagnosticEvents().filter {
            ["ui.new_task.started", "ui.new_task.succeeded"].contains($0["event"] as? String ?? "")
        }
        let newTaskStarted = try XCTUnwrap(newTaskEvents.first { $0["event"] as? String == "ui.new_task.started" })
        let newTaskSucceeded = try XCTUnwrap(newTaskEvents.first { $0["event"] as? String == "ui.new_task.succeeded" })
        let successAttemptID = try XCTUnwrap(newTaskStarted["attemptID"] as? String)
        XCTAssertFalse(successAttemptID.isEmpty)
        XCTAssertEqual(newTaskSucceeded["attemptID"] as? String, successAttemptID)
        XCTAssertEqual(newTaskSucceeded["taskID"] as? String, createdTaskID)
        XCTAssertNotNil(newTaskSucceeded["durationMilliseconds"] as? String)
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

    // case-contract: test_new_task_failure_diagnostics | A real directory at the task-store write-lock path makes CLI task creation fail with operation_failed and leaves no task persisted; the paired New Task button shows the save error and writes correlated start and failure diagnostics with the same attempt ID, error domain, and code.
    func test_new_task_failure_diagnostics() throws {
        launchApp(defaultParent: fixture.parent.path)
        let writeLock = dataDirectory.appendingPathComponent("store-write.lock", isDirectory: true)
        let missingLockTarget = dataDirectory.appendingPathComponent("missing-lock-parent/store-write.lock")
        try FileManager.default.createSymbolicLink(at: writeLock, withDestinationURL: missingLockTarget)

        element("new-task-button").click()
        let saveAlert = app.alerts["Couldn't save changes"]
        XCTAssertTrue(saveAlert.waitForExistence(timeout: 10), "A real store-lock open failure should be shown to the user.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains { $0["event"] as? String == "ui.new_task.failed" }) ?? false
        }, timeout: 2), "The New Task failure should reach the diagnostics file promptly.")
        let events = try diagnosticEvents()
        let failure = try XCTUnwrap(events.last { $0["event"] as? String == "ui.new_task.failed" })
        let starts = events.filter { $0["event"] as? String == "ui.new_task.started" }
        let start = try XCTUnwrap(starts.last)
        let failureAttemptID = try XCTUnwrap(start["attemptID"] as? String)
        XCTAssertFalse(failureAttemptID.isEmpty)
        XCTAssertEqual(failure["attemptID"] as? String, failureAttemptID)
        XCTAssertFalse((failure["errorDomain"] as? String ?? "").isEmpty)
        XCTAssertFalse((failure["errorCode"] as? String ?? "").isEmpty)
        XCTAssertNotNil(failure["durationMilliseconds"] as? String)

        saveAlert.buttons["OK"].click()
        try FileManager.default.removeItem(at: writeLock)
        XCTAssertTrue(try tasksFromBoardList().isEmpty, "A failed create must not leave a persisted task.")
    }

    // case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while the composer automatically saves an unsent prompt as it is typed; clearing the composer clears the stored draft, backing out needs no Save button, and reopening restores the draft without creating a branch or worktree. Blank drafts cannot be stored, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text.
    func test_task_prompt_draft_persists_after_back() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-title-success-wait").path
        launchApp(defaultParent: fixture.parent.path)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Task creation should open its conversation immediately.")
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
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
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
        let stableTitle = try runCLI(["task", "get", taskID])["result"] as? [String: Any]
        XCTAssertEqual(stableTitle?["title"] as? String, "Stable draft title", "Returning with the saved draft should not restart title generation.")
        attachScreenshot(named: "Unsent task prompt is saved after returning to backlog")
    }

    // case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline at the caret without sending and Return submits; multiline prompts persist as typed text, the composer expands beyond five lines, stops at its 12-line limit, and retains all lines while scrolling. Long saved drafts reopen intact and immediately expand before typing, including after restart, remain editable, grow for wrapped text, shrink when shortened, and show their own overflow scrollbar for earlier and later content. The CLI/XPC preserves a 15-line draft. Long submitted prompts persist through CLI/XPC, and the UI transcript shows a scrollbar for overflow with scrolling that reveals earlier and later content. Blank drafts cannot be sent or stored, sent prompts persist in conversation history through reload, and backing out immediately after send preserves the submitted prompt as a sent message while title generation is pending. The CLI rejects submitted-prompt saves unless they include nonblank text and In Progress status. The CLI/XPC and UI also recover a submitted prompt that has no Codex thread or active send reservation: the task becomes Blocked, the pending marker clears, and the prompt returns to the composer. Sending to an Untitled auto-branch task derives its branch from the Codex-generated title or from the prompt fallback when title generation fails. During title preparation, CLI/XPC confirms the submitted prompt and conversation thread remain attached to the task, while the UI keeps Pause disabled until the task's conversation client has an interruptible turn. Persistent diagnostics correlate title generation and application outcomes with the task and Codex thread, record failure or skip reasons, and exclude prompt and title text, including text echoed in server errors. Queued follow-ups persist with task and thread identity across fresh CLI/XPC reads, dispatch once after the next completed turn, and disappear from the queue after completion. During an active turn, Return queues a follow-up, queued rows offer Steer, and queued follow-ups persist across reopening. The obsolete footer Queue and Steer buttons are absent.
    func test_conversation_composer_rejects_blank_and_supports_live_turn_controls() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Blank message", roots: [fixture.primary.path])
        let longDraftTaskID = try taskID(named: "Blank message")
        let longDraft = "# Inspect subagents\n" + String(repeating: "Review child activity and preserve the complete result.\n", count: 160)
        _ = try runCLI(["task", "prompt", longDraftTaskID, "--text", longDraft])
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Blank message")
        let draftEditor = element("message-composer")
        let editorViewport = element("message-composer-scroll-view")
        XCTAssertTrue(draftEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(draftEditor.elementType, .textView, "The composer should use a native multiline text area.")
        XCTAssertEqual(draftEditor.value as? String, longDraft)
        XCTAssertTrue(waitUntil({ editorViewport.frame.height >= 239 }, timeout: 5), "Opening a saved long draft must expand the visible editor immediately, before typing.")
        XCTAssertLessThanOrEqual(editorViewport.frame.height, 241, "A long draft must not expand the editor beyond its viewport cap.")
        attachScreenshot(named: "Long saved draft expands the native composer")
        let draftTopPosition = draftEditor.frame.minY
        editorViewport.swipeUp()
        XCTAssertTrue(editorViewport.scrollBars.firstMatch.waitForExistence(timeout: 5), "Scrolling overflow must expose the composer's own native scrollbar.")
        XCTAssertTrue(waitUntil({ draftEditor.frame.minY < draftTopPosition - 20 }, timeout: 5), "Scrolling down must reveal later draft content.")
        let draftLowerPosition = draftEditor.frame.minY
        editorViewport.swipeDown()
        XCTAssertTrue(waitUntil({ draftEditor.frame.minY > draftLowerPosition + 20 }, timeout: 5), "Scrolling up must reveal earlier draft content.")
        draftEditor.click()
        draftEditor.typeKey(.downArrow, modifierFlags: .command)
        draftEditor.typeText("Edited after reopening.")
        let editedDraft = longDraft + "Edited after reopening."
        XCTAssertTrue(waitUntil({ draftEditor.value as? String == editedDraft }, timeout: 5), "The reopened long draft must respond to editing.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longDraftTaskID)?["savedPrompt"] as? String) == editedDraft }, timeout: 10))
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5), "Back must remain responsive after editing a long draft.")
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Blank message")
        XCTAssertEqual(draftEditor.value as? String, editedDraft)
        XCTAssertTrue(waitUntil({ editorViewport.frame.height >= 239 }, timeout: 5), "The editor must also expand after restarting with a saved draft.")
        draftEditor.click()
        draftEditor.typeKey("a", modifierFlags: .command)
        draftEditor.typeText("Short")
        let shortenedEditor = waitUntil({ editorViewport.frame.height < 60 }, timeout: 5)
        if !shortenedEditor {
            attachScreenshot(named: "Composer after shortening a saved long draft")
        }
        XCTAssertTrue(shortenedEditor, "Shortening the draft should shrink the editor; viewport=\(editorViewport.frame), document=\(draftEditor.frame), text=\(draftEditor.value ?? "")")
        let shortHeight = editorViewport.frame.height
        draftEditor.typeKey("a", modifierFlags: .command)
        draftEditor.typeText(String(repeating: "Wrapped text without a newline. ", count: 30))
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight + 20 }, timeout: 5), "Wrapping must grow the editor without explicit newlines.")
        draftEditor.typeKey("a", modifierFlags: .command)
        draftEditor.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: longDraftTaskID)?["savedPrompt"] as? String) == nil }, timeout: 10))
        let composer = element("message-composer")
        let sendButton = element("send-message-button")
        let modelPicker = app.popUpButtons.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10), "The composer should show the selected model next to its send controls.")
        let modelTaskID = try taskID(named: "Blank message")
        let modelResult = try runCLI(["conversation", "models", modelTaskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        let selectedModelValue = (modelPicker.value as? String ?? modelPicker.label)
            .split(separator: ":").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(availableModels.contains(where: {
            selectedModelValue.caseInsensitiveCompare($0["name"] as? String ?? "") == .orderedSame
                || selectedModelValue.caseInsensitiveCompare($0["id"] as? String ?? "") == .orderedSame
        }), "The selected composer model '\(selectedModelValue)' should match an available Codex model: \(availableModels).")
        XCTAssertFalse(sendButton.isEnabled)
        composer.click()
        composer.typeText("First line")
        composer.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight }, timeout: 5), "The composer should reserve the empty caret line immediately after a trailing newline.")
        XCTAssertEqual(composer.value as? String, "First line\n", "The trailing newline should remain in the editor before text is entered on the next line.")
        composer.typeText("Second line")
        XCTAssertEqual(composer.value as? String, "First line\nSecond line", "Shift+Enter should add a line without submitting the composer.")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > shortHeight }, timeout: 5))
        let twoLineHeight = editorViewport.frame.height
        for index in 3...5 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > twoLineHeight }, timeout: 5))
        let fiveLineHeight = editorViewport.frame.height
        for index in 6...9 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > twoLineHeight }, timeout: 5), "The visible composer should grow as a draft gains lines.")
        XCTAssertTrue(waitUntil({ editorViewport.frame.height > fiveLineHeight }, timeout: 5), "The visible composer should expand beyond the previous five-line limit.")
        for index in 10...12 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let twelveLineHeight = editorViewport.frame.height
        for index in 13...15 {
            composer.typeKey(.return, modifierFlags: .shift)
            composer.typeText("Line \(index)")
        }
        let expectedLongDraft = (["First line", "Second line"] + (3...15).map { "Line \($0)" }).joined(separator: "\n")
        XCTAssertLessThanOrEqual(editorViewport.frame.height, twelveLineHeight + 2, "The composer should stop growing at its 12-line limit and scroll the remaining draft.")
        XCTAssertEqual(composer.value as? String, expectedLongDraft, "The composer should retain all lines after reaching its scroll limit.")
        XCTAssertTrue(element("conversation-scroll-view").exists, "The transcript should expose its scroll view for reading the full conversation.")
        XCTAssertTrue(sendButton.isEnabled)
        XCTAssertEqual(((try runCLI(["conversation", "history", taskID(named: "Blank message")])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0, "Adding a line must not send a conversation message.")
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("BeforeAfter")
        composer.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<6 { composer.typeKey(.rightArrow, modifierFlags: []) }
        composer.typeKey(.return, modifierFlags: .shift)
        XCTAssertEqual(composer.value as? String, "Before\nAfter", "Shift+Return must insert at the caret, not append to the draft.")
        XCTAssertEqual(((try runCLI(["conversation", "history", modelTaskID])["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0)
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
            titleComposer.typeKey(.return, modifierFlags: [])
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
            XCTAssertTrue(transcriptScrollView.scrollBars.firstMatch.waitForExistence(timeout: 5), "An overflowing transcript should expose a visible scrollbar.")
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
            XCTAssertFalse(element("steer-current-turn-button").exists, "The old footer Steer button should be absent during a turn.")
            XCTAssertFalse(element("queue-message-after-turn-button").exists, "The old footer Queue button should be absent during a turn.")
            XCTAssertTrue(app.staticTexts["Ask for follow-up changes"].exists, "The active composer should identify follow-up changes.")
            let queuedText = "Afterward, report that the queued message was dispatched."
            composer.click()
            composer.typeText(queuedText)
            composer.typeKey(.return, modifierFlags: [])
            let queuedDuringLiveTurn = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
            XCTAssertEqual(queuedDuringLiveTurn?.first?["text"] as? String, queuedText, "Return should queue the active-turn follow-up.")
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

    // case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, the task remains In Progress while a send is active, and successful turns without outcome calls finish in Waiting Response.
    func test_conversation_serializes_concurrent_sends() throws {
        let sharedFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-concurrent-serial-success-wait")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sharedFixture.path))
        for suffix in ["resolve-ready", "resolve-continue", "serial-second-turn-started", "history"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sharedFixture.path + ".\(suffix)"))
        }
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
        XCTAssertEqual(completed["status"] as? String, "Waiting Response")

        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible("Concurrent conversation sends", inColumn: "Waiting Response")
        openTask(named: "Concurrent conversation sends")
        XCTAssertTrue(app.staticTexts[firstPrompt].waitForExistence(timeout: 10), "Reopening the task should retain the first completed send in conversation history.")
        XCTAssertTrue(app.staticTexts[secondPrompt].waitForExistence(timeout: 10), "Reopening the task should load the completed second send from the real app-server thread.")
    }

    // case-contract: test_conversation_steers_and_queues_active_turn | When a steer misses its active turn, CLI/XPC and UI accept it into the durable queue for its own turn; with no active turn, a missed queued-row steer dispatches synchronously as its own turn and leaves the queue; queued fallback survives process exit or app relaunch and is drained exactly once; a missed regular or queued-row steer arriving during targeted queue dispatch is drained afterward exactly once; a failed targeted turn remains needs-action and does not drain later messages; malformed steer images fail validation; CLI/XPC steering routes image data to a UI-owned active turn and appears in the conversation. Command-Return steers the active turn with attached text and images, then clears the accepted draft and image preview; if the active turn changes before delivery, it clears the draft and queues the complete message for its own turn. Plain Return queues a follow-up; its row Steer uses the active turn ID, appears in the transcript, and removes the item only after acceptance. The obsolete footer Queue and Steer buttons are absent and the active response control is labeled Stop response. Follow-ups persist across reopening, expose per-row Steer, delete, and more actions, and a distinct after-turn follow-up dispatches once after a matching completion and is removed only after successful delivery; removing an unknown queue ID fails without changing the queue.
    func test_conversation_steers_and_queues_active_turn() throws {
        let sharedFixture = WorkspaceFixture.root.appendingPathComponent("codex-fixture-steer-queue-serial-success-wait")
        let fixtureOwner = try String(contentsOf: WorkspaceFixture.root.appendingPathComponent(WorkspaceFixture.ownerMarker), encoding: .utf8)
        XCTAssertEqual(fixtureOwner, WorkspaceFixture.ownerContents, "Only the prepared, owned fixture root may contain the executable app-server fixture.")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sharedFixture.path), "The focused active-turn fixture should be prepared as an executable by the UI runner.")
        for suffix in ["resolve-ready", "resolve-continue", "serial-second-turn-started", "history", "reject-next-steer", "hold-next-queued-turn", "queued-turn-ready", "queued-turn-release", "fail-next-turn-start"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sharedFixture.path + ".\(suffix)"))
        }
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        codexFixtureExecutable = sharedFixture.path
        launchWindowTitle = "StationAI · steer-queue-test"
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title == %@", launchWindowTitle!)).firstMatch.waitForExistence(timeout: 5), "The configured launch title should identify the worktree in the window chrome.")
        try createTaskFixture(title: "Active turn message controls", roots: [fixture.primary.path])
        openTask(named: "Active turn message controls")

        let taskID = try taskID(named: "Active turn message controls")
        let firstPrompt = "Start the active turn before steering and queueing."
        let steeringText = "Keep the current approach and simplify the final change."
        let missedRowSteerText = "Queue this missed row steer for its own turn."
        let rowSteeringText = "Send this queued follow-up into the active turn."
        let queuedText = "After the current work, verify the saved follow-up."
        XCTAssertTrue(app.staticTexts["Start a conversation"].waitForExistence(timeout: 15), "Conversation history should finish loading before the composer is used.")
        let composer = app.textViews.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The native message editor should be exposed as a text view.")
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
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": sharedFixture.path]
        )
        assertCLIError(invalidSteer, code: "invalid_argument")
        let cliImage = dataDirectory.appendingPathComponent("cli-steer.png")
        let cliBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(cliBitmap.representation(using: .png, properties: [:])).write(to: cliImage)
        let remoteSteer = try runCLI(["conversation", "steer", taskID, "--message", steeringText, "--image", cliImage.path])["result"] as? [String: Any]
        XCTAssertEqual(remoteSteer?["accepted"] as? Bool, true, "CLI/XPC steering should route to the UI-owned active turn.")
        XCTAssertTrue(app.staticTexts[steeringText].waitForExistence(timeout: 10))
        let transcriptImages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-image-"))
        XCTAssertTrue(transcriptImages.firstMatch.waitForExistence(timeout: 5), "An image-bearing CLI/XPC steer should render in the visible transcript. \(app.debugDescription)")
        XCTAssertEqual(transcriptImages.count, 1)
        let uiSteeringText = "Make the final change concise and focused."
        let uiBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let uiPNG = try XCTUnwrap(uiBitmap.representation(using: .png, properties: [:]))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(uiPNG, forType: .png)
        composer.click()
        composer.typeText(uiSteeringText)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "An image attached to a steer should remain previewed until accepted.")
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts[uiSteeringText].waitForExistence(timeout: 10), "Command-Return should steer the active turn with the composer text and image.")
        XCTAssertEqual(transcriptImages.count, 2)
        XCTAssertFalse(element("pending-chat-images").exists, "An accepted steer should clear its image preview.")
        XCTAssertEqual(composer.value as? String, "", "An accepted Command-Return steer should clear the draft.")
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        let missedUISteerText = "Queue this missed UI steer with its image."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(uiPNG, forType: .png)
        composer.click()
        composer.typeText(missedUISteerText)
        composer.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "The fallback steer's image should remain attached until queue acceptance.")
        composer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "" }, timeout: 10), "A missed UI steer should be accepted into the follow-up queue and clear the composer.")
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
        XCTAssertTrue(queuedRowText.waitForExistence(timeout: 10), "Queued text should be visible in its composer row. app=\(app.debugDescription)")
        XCTAssertEqual(queuedRowText.value as? String, missedRowSteerText, "The queue row should expose the actual follow-up text.")
        XCTAssertTrue(element("steer-queued-message-\(queuedID)").exists, "A queued follow-up should offer a per-row steer action.")
        XCTAssertTrue(element("queued-message-more-\(queuedID)").exists, "A queued follow-up should offer its more-actions menu.")
        element("back-to-board-button").click()
        openTask(named: "Active turn message controls")
        let reopenedQueuedRow = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(reopenedQueuedRow.waitForExistence(timeout: 10), "The queued row should render after reopening the task during the active turn.")
        XCTAssertEqual(reopenedQueuedRow.value as? String, missedRowSteerText)
        XCTAssertTrue(element("steer-queued-message-\(queuedID)").exists, "Reopening should restore the queued row Steer action.")
        try "expected active turn id stale-turn but found fixture-turn\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        element("steer-queued-message-\(queuedID)").click()
        XCTAssertFalse(element("codex-chat-error").exists, "A missed queued steer should not surface an error.")
        let fallbackQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let missedRowFallback = try XCTUnwrap(fallbackQueue?.first(where: { $0["id"] as? String == queuedID }))
        XCTAssertEqual(missedRowFallback["state"] as? String, "queued", "A missed row steer should remain queued for its own turn.")
        XCTAssertTrue(element("queued-message-text-\(queuedID)").exists, "A missed queued steer should remain visible in the queue.")
        element("back-to-board-button").click()
        openTask(named: "Active turn message controls")
        let reopenedMissedRow = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(reopenedMissedRow.waitForExistence(timeout: 10), "The missed row steer should persist in queued state after reopening.")
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
        composer.click()
        composer.typeText(rowSteeringText)
        XCTAssertEqual(composer.value as? String, rowSteeringText, "The native composer should contain the second follow-up before Return.")
        let activeTurnControl = element("pause-response-button")
        XCTAssertEqual(activeTurnControl.label, "Stop response", "The fixture turn should still be active before queueing a second follow-up.")
        XCTAssertTrue(activeTurnControl.isEnabled, "The active-turn control should be enabled before Return queues a second follow-up. app=\(app.debugDescription)")
        composer.typeKey(.return, modifierFlags: [])
        let acceptedQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        XCTAssertTrue(acceptedQueue?.contains(where: { $0["text"] as? String == rowSteeringText }) == true, "Return should queue the typed follow-up while the active turn is held. activeControl=\(element("pause-response-button").label), composer=\(composer.value as? String ?? "<none>"), error=\(element("codex-chat-error").exists ? element("codex-chat-error").label : "<none>"), fixtureHeld=\(FileManager.default.fileExists(atPath: ready.path))")
        let acceptedQueueID = try XCTUnwrap(acceptedQueue?.first(where: { $0["text"] as? String == rowSteeringText })?["id"] as? String)
        element("steer-queued-message-\(acceptedQueueID)").click()
        XCTAssertTrue(waitUntil({
            !((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == acceptedQueueID }
        }, timeout: 10), "Steering a queued row should remove it after successful delivery.")
        XCTAssertFalse(element("queued-message-text-\(acceptedQueueID)").exists, "Successful steering should remove the queued text from its row.")
        XCTAssertTrue(app.staticTexts[rowSteeringText].waitForExistence(timeout: 10), "Per-row steering should appear in the active conversation.")
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
        XCTAssertTrue(afterTurnRowText.waitForExistence(timeout: 10), "The after-turn follow-up should appear as a visible queue row before delivery.")

        try "Release the active turn.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The queued message should dispatch once after the matching completed notification.")
        XCTAssertTrue(waitUntil({ !afterTurnRowText.exists }, timeout: 10), "The accepted after-turn follow-up should disappear from the visible queue.")
        XCTAssertTrue(app.staticTexts[queuedText].waitForExistence(timeout: 10), "The accepted after-turn follow-up should appear in the conversation transcript.")
        let targetedText = "Retry this row as its own turn."
        composer.click()
        composer.typeText(targetedText)
        composer.typeKey(.return, modifierFlags: [])
        let targetedRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == targetedText }))
        let targetedID = try XCTUnwrap(targetedRow["id"] as? String)
        try "hold targeted delivery\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(targetedID)").waitForExistence(timeout: 5))
        element("steer-queued-message-\(targetedID)").click()
        let targetedReady = URL(fileURLWithPath: sharedFixture.path + ".queued-turn-ready")
        let targetedRelease = URL(fileURLWithPath: sharedFixture.path + ".queued-turn-release")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 10), "A row steer with no active turn should start a targeted own-turn delivery.")
        let overlapText = "Queue this steer behind the targeted turn."
        try "no active turn to steer\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        let overlapSteer = try runCLI(["conversation", "steer", taskID, "--message", overlapText], extraEnvironment: [
            "STATIONAI_E2E_CODEX_EXECUTABLE": sharedFixture.path
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
        composer.click()
        composer.typeText(targetedRowText)
        composer.typeKey(.return, modifierFlags: [])
        let targetedRowOverlap = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == targetedRowText }))
        let targetedRowID = try XCTUnwrap(targetedRowOverlap["id"] as? String)
        try "hold targeted row delivery\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".hold-next-queued-turn"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(targetedRowID)").waitForExistence(timeout: 5))
        element("steer-queued-message-\(targetedRowID)").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: targetedReady.path) }, timeout: 10), "The targeted row turn should be held while a second row steer is submitted.")
        let missedRowOverlapText = "Queue this missed row steer behind targeted dispatch."
        composer.click()
        composer.typeText(missedRowOverlapText)
        composer.typeKey(.return, modifierFlags: [])
        let missedRowOverlap = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["text"] as? String == missedRowOverlapText }))
        let missedRowOverlapID = try XCTUnwrap(missedRowOverlap["id"] as? String)
        try "expected active turn id stale-turn but found fixture-turn\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(missedRowOverlapID)").waitForExistence(timeout: 5))
        element("steer-queued-message-\(missedRowOverlapID)").click()
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).first(where: { $0["id"] as? String == missedRowOverlapID })?["state"] as? String == "queued"
        }, timeout: 10), "The missed queued-row steer should remain queued until the targeted turn ends.")
        relaunchApp()
        openTask(named: "Active turn message controls")
        let relaunchedMissedRow = element("queued-message-text-\(missedRowOverlapID)")
        XCTAssertTrue(relaunchedMissedRow.waitForExistence(timeout: 10), "The missed queued-row steer should remain visible after app relaunch.")
        XCTAssertEqual(relaunchedMissedRow.value as? String, missedRowOverlapText)
        let persistedMissedRow = try XCTUnwrap((try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]])?.first(where: { $0["id"] as? String == missedRowOverlapID }))
        XCTAssertEqual(persistedMissedRow["state"] as? String, "queued", "App relaunch must not turn a durable queued steer into Needs action.")
        try "Release targeted row delivery.\n".write(to: targetedRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 20), "The pending drain should deliver the missed queued-row steer after targeted delivery.")
        XCTAssertFalse(element("codex-chat-error").exists, "A missed queued-row steer during targeted delivery should not show an error.")
        let immediateSteerText = "Deliver this missed row immediately as its own turn."
        let immediateRow = try XCTUnwrap(try runCLI(["conversation", "queue", taskID, "--message", immediateSteerText])["result"] as? [String: Any])
        let immediateRowID = try XCTUnwrap(immediateRow["id"] as? String)
        let immediateSteerButton = element("steer-queued-message-\(immediateRowID)")
        XCTAssertTrue(immediateSteerButton.waitForExistence(timeout: 10), "A queued follow-up should be visible while no turn is active.")
        immediateSteerButton.click()
        XCTAssertTrue(app.staticTexts[immediateSteerText].waitForExistence(timeout: 10), "A missed steer with no active turn should be delivered visibly in its own turn.")
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []).isEmpty
        }, timeout: 10), "The synchronous own-turn drain should remove the queued row before completion is reported.")
        let immediateHistory = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let immediateMessages = (immediateHistory?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(immediateMessages.filter { $0["text"] as? String == immediateSteerText }.count, 1)
        let failedTargetText = "This targeted queued turn should need action."
        let laterText = "Keep this later message queued after a failure."
        composer.click()
        composer.typeText(failedTargetText)
        composer.typeKey(.return, modifierFlags: [])
        composer.typeText(laterText)
        composer.typeKey(.return, modifierFlags: [])
        let failureQueue = try runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]
        let failedTarget = try XCTUnwrap(failureQueue?.first(where: { $0["text"] as? String == failedTargetText }))
        let laterItem = try XCTUnwrap(failureQueue?.first(where: { $0["text"] as? String == laterText }))
        let failedTargetID = try XCTUnwrap(failedTarget["id"] as? String)
        let laterID = try XCTUnwrap(laterItem["id"] as? String)
        try "fail targeted turn start\n".write(to: URL(fileURLWithPath: sharedFixture.path + ".fail-next-turn-start"), atomically: true, encoding: .utf8)
        XCTAssertTrue(element("steer-queued-message-\(failedTargetID)").waitForExistence(timeout: 5))
        element("steer-queued-message-\(failedTargetID)").click()
        XCTAssertTrue(waitUntil({
            let items = (try? self.runCLI(["conversation", "queue-list", taskID])["result"] as? [[String: Any]]) ?? []
            return items.first(where: { $0["id"] as? String == failedTargetID })?["state"] as? String == "needsAction" &&
                items.first(where: { $0["id"] as? String == laterID })?["state"] as? String == "queued"
        }, timeout: 10), "A failed targeted turn should need action while later follow-ups stay queued.")
        let needsActionIndicator = element("queued-message-needs-action-\(failedTargetID)")
        XCTAssertTrue(needsActionIndicator.waitForExistence(timeout: 5), "The failed targeted row should visibly require user action.")
        XCTAssertEqual(needsActionIndicator.label, "Follow-up needs your action")
        XCTAssertTrue(element("retry-queued-message-\(failedTargetID)").exists, "The failed targeted row should expose its retry action.")
        XCTAssertTrue(element("queued-message-text-\(laterID)").exists, "The later queued row should remain visible after the targeted failure.")
        let history = try runCLI(["conversation", "history", taskID], extraEnvironment: [
            "STATIONAI_E2E_CODEX_EXECUTABLE": sharedFixture.path
        ])["result"] as? [String: Any]
        let userMessages = (history?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(userMessages.compactMap { $0["text"] as? String }.filter { $0 == queuedText }.count, 1)
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
        XCTAssertEqual((fixtureHistory["rejectedSteerRequests"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(steerRequests.count, 3)
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
        XCTAssertEqual(steerRequests[2]["input"] as? [[String: String]], [["type": "text", "text": rowSteeringText]])
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 10))
    }

    // case-contract: test_conversation_sends_image_attachments | Backlog draft images persist through fresh CLI/XPC reads and reopening the conversation, with the preview restored; saving more than 8 draft images fails with invalid_argument and preserves the existing attachment. The conversation composer also accepts images from the picker and paste, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, reads Codex history image URLs, and keeps earlier images visible after a later text turn and history refresh. Diagnostics record image MIME and encoded size without storing image payloads.

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
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "Reopening a backlog task should restore its image preview.")
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
        var imageDiagnostics: [[String: Any]] = []
        XCTAssertTrue(waitUntil({
            imageDiagnostics = (try? self.diagnosticEvents()) ?? []
            return !imageDiagnostics.isEmpty
        }, timeout: 5), "The visible attachment send should leave diagnostics.")
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: imageDiagnostics), encoding: .utf8)?.contains(pickedImage) ?? true)
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture_1").waitForExistence(timeout: 10), "Reloaded history should retain the picker attachment.")
        XCTAssertTrue(app.images["user-message-item_user_fixture_1"].waitForExistence(timeout: 10), "Conversation history should render the picker image.")

        let followupPrompt = "Continue using the earlier image as context."
        composer.click()
        composer.typeText(followupPrompt)
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10), "The follow-up turn should refresh the existing conversation history.")
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts[followupPrompt].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil({
            self.app.staticTexts.matching(NSPredicate(format: "label == %@", "Answers received: Blue / fixture-secret.")).count == 2
        }, timeout: 10), "The follow-up turn should complete and replace the transcript from Codex history.")
        XCTAssertTrue(waitUntil({
            self.app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-image-")).count == 1
        }, timeout: 10), "Refreshing history after another turn should keep the earlier image visible.")
        let refreshedHistory = try runCLI(["conversation", "history", try taskID(named: "Image conversation")])["result"] as? [String: Any]
        let refreshedUserMessages = (refreshedHistory?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        XCTAssertEqual(refreshedUserMessages.first?["imageDataURLs"] as? [String], [pickedImage], "A fresh XPC history read should retain the earlier image after a later turn.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10))
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
        XCTAssertTrue(pasteMenuItem.waitForExistence(timeout: 5))
        XCTAssertTrue(pasteMenuItem.isEnabled, "The native text editor must enable Paste for an image-only clipboard.")
        pasteMenuItem.click()
        XCTAssertTrue(element("pending-chat-images").waitForExistence(timeout: 5), "Pasting an image should create a composer preview.")
        element("send-message-button").click()
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(app.staticTexts["Answers received: Blue / fixture-secret."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("user-message-item_user_fixture_1").waitForExistence(timeout: 10), "History reload should leave the pasted attachment in the conversation.")
        XCTAssertTrue(app.images["user-message-item_user_fixture_1"].waitForExistence(timeout: 10), "Conversation history should render the pasted image itself.")
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

    // case-contract: test_conversation_shows_mcp_and_dynamic_tool_activity | MCP and dynamic tool lifecycle updates coalesce by stable item ID into distinct visible conversation rows; each call reports its start and measured duration, and completed durations persist through history reload. The conversation header shows only the newest active call; when it completes, the indicator falls back to the next still-active call. The expanded Working for list shows each call's live or completed duration. In-progress, completed, and failed statuses, server/tool identity, and safe result summaries render without duplicate rows, including when later-turn items follow the calls in history. Arguments and raw result text are never exposed.
    func test_conversation_shows_mcp_and_dynamic_tool_activity() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-tool-activity").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(codexFixtureExecutable)))
        launchApp(defaultParent: fixture.primary.path)
        _ = try runCLI(["task", "create", "--title", "Tool activity", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Tool activity")
        openTask(named: "Tool activity")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Show tool activity.")
        element("send-message-button").click()

        let fixture = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable))
        let toolReady = URL(fileURLWithPath: fixture.path + ".tool-ready")
        let toolReleaseLatest = URL(fileURLWithPath: fixture.path + ".tool-release-latest")
        let toolRelease = URL(fileURLWithPath: fixture.path + ".tool-release")
        defer {
            try? "Release newest tool after assertion failure.\n".write(to: toolReleaseLatest, atomically: true, encoding: .utf8)
            try? "Release tool completions after assertion failure.\n".write(to: toolRelease, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: toolReady.path) }, timeout: 20), "The fixture should pause after the tool start notifications.")
        let currentActivity = element("current-activity-title")
        XCTAssertTrue(waitUntil({ currentActivity.label == "Tool · legacySummary" }, timeout: 10), "The header should show the most recently started active call.")
        XCTAssertTrue(element("current-activity-duration").exists, "The current activity should show its elapsed time outside the disclosure.")
        element("codex-activity-disclosure").click()
        let activityDetails = element("codex-activity-details")
        XCTAssertTrue(activityDetails.waitForExistence(timeout: 5), "Expanded Working for should contain tool activity rows.")
        func containsPositiveDuration(_ value: String) -> Bool {
            value.range(of: #"Duration · [1-9][0-9]* ms"#, options: .regularExpression) != nil
        }
        func containsPositiveRunningDuration(_ value: String) -> Bool {
            value.range(of: #"Running · [1-9][0-9]* ms"#, options: .regularExpression) != nil
        }
        let mcpRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").firstMatch
        let dynamicRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").firstMatch
        let legacyDynamicRow = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").firstMatch
        XCTAssertTrue(mcpRow.waitForExistence(timeout: 10), "MCP calls should appear inside expanded Working for while in progress.")
        XCTAssertTrue(dynamicRow.waitForExistence(timeout: 10), "Dynamic tool calls should appear inside expanded Working for while in progress.")
        XCTAssertTrue(legacyDynamicRow.waitForExistence(timeout: 10), "Every active call should appear inside expanded Working for.")
        for identifier in ["item_fixture_mcp_call", "item_fixture_dynamic_call", "item_fixture_dynamic_legacy"] {
            let liveDuration = activityDetails.descendants(matching: .any).matching(identifier: "codex-activity-duration-\(identifier)").firstMatch
            XCTAssertTrue(liveDuration.exists, "Expanded Working for should show a live duration for \(identifier).")
            XCTAssertTrue(containsPositiveRunningDuration(liveDuration.value as? String ?? ""), "The live duration for \(identifier) should contain positive elapsed time in milliseconds.")
        }
        XCTAssertTrue(mcpRow.label.contains("In progress"))
        XCTAssertTrue(dynamicRow.label.contains("In progress"))
        XCTAssertTrue(legacyDynamicRow.label.contains("In progress"))
        try "Finish the newest call first.\n".write(to: toolReleaseLatest, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ currentActivity.label == "Tool · summarize" }, timeout: 15), "When the newest call finishes, the header should fall back to the next active call.")
        XCTAssertTrue(waitUntil({ legacyDynamicRow.label.contains("Completed") }, timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").count, 1)
        try "Release tool completions.\n".write(to: toolRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ mcpRow.label.contains("Completed") && dynamicRow.label.contains("Failed") && legacyDynamicRow.label.contains("Completed") }, timeout: 30), "Lifecycle completions should update the existing rows.")
        XCTAssertTrue(mcpRow.label.contains("MCP · lookup"))
        XCTAssertTrue((mcpRow.value as? String ?? "").contains("fixture-server"))
        XCTAssertTrue((mcpRow.value as? String ?? "").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(mcpRow.value as? String ?? ""), "The completed MCP call should display its positive measured duration in milliseconds.")
        XCTAssertTrue((dynamicRow.value as? String ?? "").contains("Tool call failed"))
        XCTAssertTrue((dynamicRow.value as? String ?? "").contains("Duration · 37 ms"))
        XCTAssertTrue(dynamicRow.label.contains("Tool · summarize"))
        XCTAssertTrue(legacyDynamicRow.label.contains("Tool · legacySummary"))
        XCTAssertTrue((legacyDynamicRow.value as? String ?? "").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(legacyDynamicRow.value as? String ?? ""), "The completed legacy call should display its positive measured duration in milliseconds.")
        let renderedToolRows = "\(mcpRow.label) \(mcpRow.value ?? "") \(dynamicRow.label) \(dynamicRow.value ?? "") \(legacyDynamicRow.label) \(legacyDynamicRow.value ?? "")"
        XCTAssertFalse(renderedToolRows.contains("RAW_ARGUMENT_SECRET"))
        XCTAssertFalse(renderedToolRows.contains("RAW_RESULT_SECRET"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").count, 1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").count, 1)

        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        let savedActivities = history?["activities"] as? [[String: Any]] ?? []
        XCTAssertEqual(savedActivities.filter { $0["id"] as? String == "item_fixture_mcp_call" }.count, 1)
        XCTAssertEqual(savedActivities.filter { $0["id"] as? String == "item_fixture_dynamic_call" }.count, 1)
        element("back-to-board-button").click()
        openTask(named: "Tool activity")
        element("codex-activity-disclosure").click()
        let reloadedActivityDetails = element("codex-activity-details")
        XCTAssertTrue(reloadedActivityDetails.waitForExistence(timeout: 5))
        let reloadedMcpRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_mcp_call").firstMatch
        XCTAssertTrue(reloadedMcpRow.waitForExistence(timeout: 20), "Completed MCP activity should remain in Working for after history reload.")
        let reloadedDynamicRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_call").firstMatch
        let reloadedLegacyDynamicRow = reloadedActivityDetails.descendants(matching: .any).matching(identifier: "codex-activity-row-item_fixture_dynamic_legacy").firstMatch
        XCTAssertTrue(reloadedDynamicRow.waitForExistence(timeout: 10), "Failed dynamic activity should remain after history reload.")
        XCTAssertTrue(reloadedLegacyDynamicRow.waitForExistence(timeout: 10), "Legacy dynamic activity should remain after history reload.")
        XCTAssertTrue(reloadedMcpRow.label.contains("MCP · lookup"))
        XCTAssertTrue(reloadedMcpRow.label.contains("Completed"))
        XCTAssertTrue((reloadedMcpRow.value as? String ?? "").contains("fixture-server"))
        XCTAssertTrue((reloadedMcpRow.value as? String ?? "").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(reloadedMcpRow.value as? String ?? ""), "The positive MCP duration must survive history reload in milliseconds.")
        XCTAssertTrue(reloadedDynamicRow.label.contains("Tool · summarize"))
        XCTAssertTrue(reloadedDynamicRow.label.contains("Failed"))
        XCTAssertTrue((reloadedDynamicRow.value as? String ?? "").contains("Tool call failed"))
        XCTAssertTrue((reloadedDynamicRow.value as? String ?? "").contains("Duration · 37 ms"), "Optional duration should survive history reload and render.")
        XCTAssertTrue(reloadedLegacyDynamicRow.label.contains("Tool · legacySummary"))
        XCTAssertTrue(reloadedLegacyDynamicRow.label.contains("Completed"))
        XCTAssertTrue((reloadedLegacyDynamicRow.value as? String ?? "").contains("Returned 1 result item"))
        XCTAssertTrue(containsPositiveDuration(reloadedLegacyDynamicRow.value as? String ?? ""), "The positive legacy tool duration must survive history reload in milliseconds.")
        let reloadedToolRows = reloadedMcpRow.label + " " + (reloadedMcpRow.value as? String ?? "")
            + " " + reloadedDynamicRow.label + " " + (reloadedDynamicRow.value as? String ?? "")
            + " " + reloadedLegacyDynamicRow.label + " " + (reloadedLegacyDynamicRow.value as? String ?? "")
        XCTAssertFalse(reloadedToolRows.contains("RAW_ARGUMENT_SECRET"))
        XCTAssertFalse(reloadedToolRows.contains("RAW_RESULT_SECRET"))
        XCTAssertTrue(app.staticTexts["A later turn starts."].exists, "The fixture history must include a subsequent turn after these tool calls.")
    }

    // case-contract: test_conversation_shows_context_compaction | contextCompaction item/started and item/completed coalesce into one concise timeline event; missing summaries ignore malformed opaque payload fields and never render their data, and the event survives thread history reload with correct prompt/response ordering.
    func test_conversation_shows_context_compaction() throws {
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-context-compaction").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(codexFixtureExecutable)))
        launchApp(defaultParent: fixture.primary.path)
        _ = try runCLI(["task", "create", "--title", "Context compaction", "--root", fixture.primary.path])
        let taskID = try taskID(named: "Context compaction")
        openTask(named: "Context compaction")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Compact the context.")
        element("send-message-button").click()

        let executable = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable))
        let ready = URL(fileURLWithPath: executable.path + ".compaction-ready")
        let release = URL(fileURLWithPath: executable.path + ".compaction-release")
        defer { try? "Release compaction after assertion failure.\n".write(to: release, atomically: true, encoding: .utf8) }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20))
        let row = element("context-compaction-row-item_stationai_compaction")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("In progress"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_stationai_compaction").count, 1)
        XCTAssertFalse((row.label + " " + (row.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        try "Release context compaction.\n".write(to: release, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({ row.label.contains("Completed") }, timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_stationai_compaction").count, 1)
        XCTAssertFalse((row.label + " " + (row.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        let finalMessage = app.staticTexts["Context compaction completed."]
        XCTAssertTrue(finalMessage.waitForExistence(timeout: 10))
        XCTAssertLessThan(row.frame.minY, finalMessage.frame.minY)
        let history = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((history?["activities"] as? [[String: Any]] ?? []).filter { $0["isContextCompaction"] as? Bool == true }.count, 1)
        element("back-to-board-button").click()
        openTask(named: "Context compaction")
        let reloaded = element("context-compaction-row-item_stationai_compaction")
        XCTAssertTrue(reloaded.waitForExistence(timeout: 20))
        XCTAssertTrue(reloaded.label.contains("Completed"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "context-compaction-row-item_stationai_compaction").count, 1)
        XCTAssertFalse((reloaded.label + " " + (reloaded.value as? String ?? "")).contains("COMPACTION_OPAQUE_SENTINEL"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "COMPACTION_OPAQUE_SENTINEL")).count, 0)
        XCTAssertLessThan(reloaded.frame.minY, app.staticTexts["Context compaction completed."].frame.minY)
    }

    // case-contract: test_conversation_shows_subagent_delegation | During a parent turn, active agents appear as individual named rows outside the collapsed Worked for disclosure, with available path/model/reasoning metadata and started-working wording. When the final answer arrives, all agent rows collapse inside Worked for alongside other Codex activity; expanding it reveals clickable agent rows. The UI fixture pauses after the final answer to verify this before turn completion while Stop response remains available. Completed, interrupted, and unknown states survive history reload and remain inspectable after reopening. The child thread opens as read-only through thread/read, thread/turns/list, and thread/items/list without editable controls or thread/resume, and diagnostics retain safe RPC outcomes while excluding conversation text, command output, and diffs. Multiple Codex message deltas and command-output deltas are summarized per item with counts and byte totals, flushed at turn completion, and excluded from individual notification records; lifecycle notifications remain individually logged, and diagnostics exclude conversation text, command output, and diffs.
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
        let finalAnswerPause = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-pause")
        let finalAnswerReady = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-ready")
        let finalAnswerRelease = URL(fileURLWithPath: fixtureCopy.path + ".final-answer-release")
        try? FileManager.default.removeItem(at: finalAnswerReady)
        try? FileManager.default.removeItem(at: finalAnswerRelease)
        try "Pause final answer until the UI checks the collapsed disclosure.\n".write(to: finalAnswerPause, atomically: true, encoding: .utf8)
        defer {
            try? "Release the final answer fixture.\n".write(to: finalAnswerRelease, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: finalAnswerPause)
        }
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

        let subagentReady = URL(fileURLWithPath: fixtureCopy.path + ".subagent-ready")
        let subagentRelease = URL(fileURLWithPath: fixtureCopy.path + ".subagent-release")
        defer { try? "Release active child fixture.\n".write(to: subagentRelease, atomically: true, encoding: .utf8) }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: subagentReady.path) }, timeout: 20), "The fixture should expose the active child interval before completion.")
        let activityDisclosure = element("codex-activity-disclosure")
        XCTAssertTrue(activityDisclosure.waitForExistence(timeout: 10), "Active child work should appear in conversation activity.")
        let activeChildButton = element("codex-subagent-row-00000000-0000-0000-0000-000000000002")
        XCTAssertTrue(activeChildButton.waitForExistence(timeout: 10), "The running child should appear as a clickable timeline row while Codex activity is collapsed.")
        XCTAssertTrue(activeChildButton.label.contains("Sandbox review"))
        XCTAssertTrue(activeChildButton.label.contains("started working"))
        let agentIcon = activeChildButton.images.matching(NSPredicate(format: "label == %@", "Sandbox review agent icon")).firstMatch
        XCTAssertTrue(agentIcon.waitForExistence(timeout: 5), "The requested robot icon should render in the child timeline row.")
        assertSubagentIconArtwork(agentIcon)
        let secondActiveChildButton = element("codex-subagent-row-00000000-0000-0000-0000-000000000003")
        XCTAssertTrue(secondActiveChildButton.waitForExistence(timeout: 5),
                      "Every active agent should remain visible outside the collapsed Codex activity section.")
        activityDisclosure.click()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "codex-subagent-row-00000000-0000-0000-0000-000000000002").count, 1,
                       "The interacted update should update the single timeline row instead of creating a duplicate.")
        let childMetadata = activeChildButton.value as? String ?? ""
        XCTAssertTrue(childMetadata.contains("/agents/Sandbox review"))
        XCTAssertTrue(childMetadata.contains("gpt-6-sol"))
        XCTAssertTrue(childMetadata.contains("high"))
        XCTAssertTrue(secondActiveChildButton.waitForExistence(timeout: 5))
        XCTAssertTrue(secondActiveChildButton.label.contains("Some agent"), "Underscored agent names should render with spaces and sentence capitalization.")
        XCTAssertTrue(secondActiveChildButton.label.contains("started working"))
        let secondChildMetadata = secondActiveChildButton.value as? String ?? ""
        XCTAssertTrue(secondChildMetadata.contains("/agents/some_agent"))
        XCTAssertFalse(secondChildMetadata.contains("gpt-"), "Optional child model metadata may be absent.")
        activeChildButton.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitForExistence(timeout: 5))
        try "Release child to finish and answer read-only inspection requests.\n".write(to: subagentRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(element("subagent-back-button").exists)
        XCTAssertTrue(app.staticTexts["Read only"].exists)
        XCTAssertFalse(element("message-composer").exists, "The child conversation must not expose the parent composer.")
        XCTAssertFalse(element("send-message-button").exists, "The child conversation must not expose a send action.")
        let childResult = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "found the required profile")).firstMatch
        XCTAssertTrue(childResult.waitForExistence(timeout: 20), "The child view should render its stored conversation content.")
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5), "Back should return to the parent conversation.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: finalAnswerReady.path) }, timeout: 20),
                      "The fixture should pause after the final answer appears but before the turn completes.")
        XCTAssertTrue(waitUntil({
            activityDisclosure.label.contains("Worked for")
                && activityDisclosure.value as? String == "Collapsed, right chevron"
                && self.app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "The subagent inspected the project structure")).firstMatch.exists
        }, timeout: 10), "The final answer should immediately produce a clean collapsed Worked for section.")
        XCTAssertEqual(element("pause-response-button").label, "Stop response",
                       "The final-answer transition should be checked while the turn is still responding.")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should move inside Worked for as soon as the final answer arrives.")
        }
        try "Allow the parent turn to complete.\n".write(to: finalAnswerRelease, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response"
        }, timeout: 20), "The visible composer turn should finish and persist the task status.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "codex.rpc.response.succeeded" && $0["method"] as? String == "turn/start"
            }) == true
        }, timeout: 5), "Codex diagnostics should be flushed before checking turn and notification details.")
        let codexDiagnostics = try diagnosticEvents()
        let deltaSummaries = codexDiagnostics.filter { $0["event"] as? String == "codex.notification.summary" }
        XCTAssertFalse(deltaSummaries.isEmpty, "Streamed Codex deltas should be summarized rather than logged individually.")
        let messageSummary = try XCTUnwrap(deltaSummaries.first { $0["method"] as? String == "item/agentMessage/delta" })
        XCTAssertGreaterThanOrEqual(Int(messageSummary["notificationCount"] as? String ?? "0") ?? 0, 2)
        XCTAssertGreaterThan(Int(messageSummary["payloadBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertEqual(messageSummary["flushReason"] as? String, "turn_completed")
        let outputSummary = try XCTUnwrap(deltaSummaries.first { $0["method"] as? String == "item/commandExecution/outputDelta" })
        XCTAssertEqual(Int(outputSummary["notificationCount"] as? String ?? "0") ?? 0, 2)
        XCTAssertGreaterThan(Int(outputSummary["payloadBytes"] as? String ?? "0") ?? 0, 0)
        XCTAssertEqual(outputSummary["flushReason"] as? String, "turn_completed")
        XCTAssertFalse(codexDiagnostics.contains {
            $0["event"] as? String == "codex.notification"
                && ["item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"].contains($0["method"] as? String ?? "")
        }, "High-volume delta notifications should not each occupy a diagnostics record.")
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
        let loggedWorkingDirectory = try XCTUnwrap(commandDiagnostic["workingDirectory"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: loggedWorkingDirectory).resolvingSymlinksInPath().standardizedFileURL.path,
                       fixture.primary.resolvingSymlinksInPath().standardizedFileURL.path)
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
        XCTAssertFalse(serializedCodexDiagnostics.contains("CODEX_STREAMED_OUTPUT_NOT_LOGGED"))
        XCTAssertFalse(serializedCodexDiagnostics.contains(prompt), "Diagnostics must not store the conversation text.")

        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "StationAI must be foreground before inspecting the conversation.")

        XCTAssertTrue(activityDisclosure.waitForExistence(timeout: 20), "A delegated task should appear in conversation activity.")
        XCTAssertTrue(activityDisclosure.label.contains("Worked for"), "The completed turn should use the Worked for disclosure.")
        XCTAssertEqual(activityDisclosure.value as? String, "Collapsed, right chevron",
                       "The final answer should arrive with all Codex activity collapsed.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "The subagent inspected the project structure")).firstMatch.exists,
                      "The final answer should remain visible while agent details are collapsed.")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should be hidden inside the collapsed Worked for disclosure.")
        }
        activityDisclosure.click()
        let activityRow = element("codex-activity-row-item_stationai_subagent")
        XCTAssertTrue(activityRow.waitForExistence(timeout: 10))
        XCTAssertTrue(activityRow.label.contains("Task delegated to subagent"))
        XCTAssertTrue(activityRow.label.contains("Completed"))
        XCTAssertTrue(app.staticTexts["Agents used"].exists)
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000002").label.contains("finished working"))
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000003").label.contains("was interrupted"))
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000004").exists, "An unknown child kind should remain inspectable.")
        let activityDetail = element("codex-activity-detail-item_stationai_subagent")
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 5))
        let detailDescription = "\(activityDetail.label) \(activityDetail.value as? String ?? "")"
        XCTAssertTrue(detailDescription.contains("Inspect the project structure and report relevant files."))
        let childThreadID = "00000000-0000-0000-0000-000000000002"
        for method in ["thread/read", "thread/turns/list", "thread/items/list"] {
            XCTAssertTrue(codexDiagnostics.contains {
                $0["event"] as? String == "codex.rpc.request.started"
                    && $0["method"] as? String == method
                    && $0["parameter.threadId"] as? String == childThreadID
            }, "Child inspection should call \(method) for the child thread.")
        }
        XCTAssertFalse(codexDiagnostics.contains {
            $0["event"] as? String == "codex.rpc.request.started"
                && $0["method"] as? String == "thread/resume"
                && $0["parameter.threadId"] as? String == childThreadID
        }, "Inspecting a child thread must not resume it.")

        let completedChildRow = element("codex-subagent-row-00000000-0000-0000-0000-000000000002")
        completedChildRow.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitForExistence(timeout: 5),
                      "An expanded finished agent row should open its conversation.")
        XCTAssertTrue(app.staticTexts["Read only"].exists)
        XCTAssertFalse(element("message-composer").exists)
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5))

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10), "The task should close before checking its saved conversation history.")
        openTask(named: "Subagent delegation")
        XCTAssertTrue(activityDisclosure.waitForExistence(timeout: 10))
        XCTAssertTrue(activityDisclosure.label.contains("Worked for"), "The reopened final answer should retain the Worked for disclosure.")
        XCTAssertEqual(activityDisclosure.value as? String, "Collapsed, right chevron")
        for childID in ["00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000004"] {
            XCTAssertFalse(element("codex-subagent-row-\(childID)").exists,
                           "Agent rows should remain collapsed inside Worked for after reopening.")
        }
        activityDisclosure.click()
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000002").label.contains("finished working"), "The completed child should remain inspectable after reopening the task.")
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000003").label.contains("was interrupted"), "The interrupted child should remain inspectable after reopening the task.")
        XCTAssertTrue(element("codex-subagent-row-00000000-0000-0000-0000-000000000004").exists, "The unknown child kind should remain inspectable after reopening the task.")
        attachScreenshot(named: "Conversation shows and opens a subagent")
    }

    // case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode keeps planning active across completed turns and reopening; follow-up instructions start another plan turn, and Start Implementing stays enabled with an empty chat and composer, switches to Code mode, and starts an implementation turn; subsequent composer messages remain Code turns. The plan renders automatically as Markdown with visible spacing, remains selectable and copyable as one complete text view, and CLI events and bridge history preserve the exact plan text and latest implementation handoff. Multiple plan deltas are summarized per item with count and byte totals at turn completion, with no per-delta notification records and no plan text in diagnostics.
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
        let deltaHold = URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-hold")
        let deltaReady = URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-ready")
        let deltaRelease = URL(fileURLWithPath: fixtureCopy.path + ".plan-delta-release")
        try Data().write(to: deltaHold)
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

        let taskID = try taskID(named: "Plan mode Markdown")
        let emptyConversation = try runCLI(["conversation", "history", taskID])["result"] as? [String: Any]
        XCTAssertEqual((emptyConversation?["messages"] as? [[String: Any]])?.count ?? 0, 0, "The handoff availability check should start with an empty conversation.")
        XCTAssertEqual(element("message-composer").value as? String ?? "", "")
        let startImplementingInEmptyConversation = element("start-implementing-button")
        XCTAssertTrue(startImplementingInEmptyConversation.waitForExistence(timeout: 5), "Plan mode should offer Start Implementing before any chat messages exist.")
        XCTAssertTrue(startImplementingInEmptyConversation.isEnabled, "Start Implementing should be clickable with an empty conversation.")

        modeMenu.click()
        let goalComposerMode = app.menuItems["conversation-mode-goal"]
        XCTAssertTrue(goalComposerMode.waitForExistence(timeout: 5))
        goalComposerMode.click()
        XCTAssertTrue(modeMenu.label.contains("Goal"), "The composer should enter Goal mode.")
        XCTAssertTrue(startImplementingInEmptyConversation.exists, "Entering Goal mode should preserve the selected Plan mode and its handoff.")
        XCTAssertTrue(startImplementingInEmptyConversation.isEnabled)
        startImplementingInEmptyConversation.click()
        XCTAssertTrue(waitUntil({ modeMenu.label.contains("Code mode") }, timeout: 5), "The empty-chat handoff should leave Goal composer mode and switch to Code.")
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
            )["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            return history.contains { $0["role"] as? String == "user" && $0["text"] as? String == "Start implementing the plan." }
                && history.contains { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
        }, timeout: 30), "Start Implementing should create a Code turn from an empty conversation.")
        let initialFixtureData = try Data(contentsOf: URL(fileURLWithPath: fixtureCopy.path + ".history"))
        let initialFixtureHistory = try XCTUnwrap(JSONSerialization.jsonObject(with: initialFixtureData) as? [String: Any])
        let codeTurnsBeforeFollowup = (initialFixtureHistory["turns"] as? [[String: Any]] ?? []).count
        let composer = element("message-composer")
        composer.click()
        composer.typeText("Continue the implementation.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
            )["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            let userIndex = history.lastIndex { $0["role"] as? String == "user" && $0["text"] as? String == "Continue the implementation." }
            let finalIndex = history.lastIndex { $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
            let fixtureData = try? Data(contentsOf: URL(fileURLWithPath: fixtureCopy.path + ".history"))
            let fixtureHistory = fixtureData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let turns = fixtureHistory?["turns"] as? [[String: Any]] ?? []
            return userIndex != nil && finalIndex != nil && finalIndex! > userIndex!
                && turns.count > codeTurnsBeforeFollowup
                && turns.last?["conversationMode"] as? String == "default"
        }, timeout: 30), "A regular composer message after handoff should start a Code turn, even when Goal was selected first.")
        modeMenu.click()
        let planModeAfterGoal = app.menuItems["Plan mode"]
        XCTAssertTrue(planModeAfterGoal.waitForExistence(timeout: 5))
        planModeAfterGoal.click()
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Plan mode should be selectable again after the Code handoff.")

        composer.click()
        composer.typeText("Plan the task.")
        element("send-message-button").click()
        let markdownReply = "## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening"
        let assistantMarkdown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Implementation plan"))
            .firstMatch
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: deltaReady.path) }, timeout: 10), "The fixture should pause after the first plan delta.")
        XCTAssertTrue(assistantMarkdown.waitForExistence(timeout: 10), "The first plan delta should appear before the turn completes.")
        XCTAssertTrue(assistantMarkdown.label.contains("workspace model"), "The partial plan should show its streamed content.")
        XCTAssertTrue(assistantMarkdown.label.contains("\n\n"), "Distinct Markdown paragraphs should retain visible spacing.")
        XCTAssertFalse(assistantMarkdown.label.contains("Final verification"), "The rest of the plan should wait for the fixture release.")
        try Data().write(to: deltaRelease)
        XCTAssertTrue(waitUntil({ assistantMarkdown.label.contains("Final verification") }, timeout: 30), "The completed plan should replace the partial plan.")
        try FileManager.default.removeItem(at: deltaHold)
        XCTAssertTrue(modeMenu.label.contains("Plan mode"), "Plan mode should stay selected after a planning response completes.")
        XCTAssertFalse(assistantMarkdown.label.contains("<proposed_plan>"), "The plan should be shown automatically without its protocol wrapper.")
        XCTAssertFalse(assistantMarkdown.label.contains("</proposed_plan>"), "The closing protocol wrapper should not be visible.")

        composer.click()
        composer.typeText("Revise the plan to clarify the persistence step.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
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
            extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
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
        let reloadedAssistant = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistant-message-", "Implementation plan"))
            .firstMatch
        XCTAssertTrue(reloadedAssistant.waitForExistence(timeout: 10), "The completed plan should appear automatically after reopening.")
        XCTAssertTrue(reloadedAssistant.label.contains("\n\n"), "Paragraph spacing should remain visible after reopening.")
        XCTAssertFalse(reloadedAssistant.label.contains("<proposed_plan>"), "The reloaded plan should hide its opening protocol wrapper.")
        XCTAssertFalse(reloadedAssistant.label.contains("</proposed_plan>"), "The reloaded plan should hide its closing protocol wrapper.")
        let markdownContent = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Implementation plan")
        ).firstMatch
        XCTAssertTrue(markdownContent.waitForExistence(timeout: 5), "The plan should render as one selectable Markdown text view.")
        markdownContent.click()
        markdownContent.typeKey("a", modifierFlags: .command)
        markdownContent.typeKey("c", modifierFlags: .command)
        let copiedPlan = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedPlan.contains("Implementation plan"), "Selecting all should include the plan heading.")
        XCTAssertTrue(copiedPlan.contains("Implementation detail 01"), "Selecting all should include the first list item.")
        XCTAssertTrue(copiedPlan.contains("Implementation detail 15"), "Selecting all should include content from the middle of the plan.")
        XCTAssertTrue(copiedPlan.contains("Final verification: confirm the latest message is visible after reopening"), "Selecting all should include the final plan item.")
        let latestListItem = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Final verification: confirm the latest message is visible after reopening"))
            .firstMatch
        let conversationScrollView = element("conversation-scroll-view")
        XCTAssertTrue(waitUntil({
            latestListItem.frame.maxY <= conversationScrollView.frame.maxY + 2
                && latestListItem.frame.maxY > conversationScrollView.frame.minY
        }, timeout: 5), "Reopening a long conversation should position its final message in the visible viewport.")
        let startImplementing = element("start-implementing-button")
        XCTAssertTrue(startImplementing.waitForExistence(timeout: 5), "Plan mode should offer a dedicated implementation handoff.")
        XCTAssertEqual(element("message-composer").value as? String ?? "", "", "The handoff should be available while the composer is empty.")
        XCTAssertTrue(startImplementing.isEnabled, "Start Implementing should not require draft text.")
        startImplementing.click()
        XCTAssertTrue(waitUntil({ element("conversation-mode-menu").label.contains("Code mode") }, timeout: 5), "Starting implementation should switch the composer to Code mode.")
        XCTAssertTrue(waitUntil({
            let history = (try? runCLI(
                ["conversation", "history", taskID],
                extraEnvironment: ["STATIONAI_E2E_CODEX_EXECUTABLE": fixtureCopy.path]
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

    // case-contract: test_thread_goal_lifecycle_persists_through_cli_xpc | CLI/XPC Goal set/get/pause/resume/clear persist the objective and lifecycle state across fresh connections and enable the Goals app-server feature; setting the same active Goal preserves its timer generation, clearing then setting another Goal creates a new generation with a fresh baseline, setting a Goal moves the task to In Progress, and invalid blank objectives preserve the current Goal. The UI restores saved Goals; the opt-in live Codex integration confirms native startup, verifies the first Goal retains its elapsed duration, restores a legacy completion without timing metadata, and confirms a second Goal timer begins near zero; renders each achieved summary as a conversation item that visibly moves with scrolling and is anchored to its completing turn, verifies a later user follow-up appears after the prior achievement through turn completion, and preserves both items and their ordering in the read-only Done archive. Native turn activation is owned by the retained GUI runtime.
    func test_thread_goal_lifecycle_persists_through_cli_xpc() throws {
        codexFixtureExecutable = nil
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("codex-home"), withIntermediateDirectories: true)
        let usesLiveCodex = isLiveCodexIntegration
        if usesLiveCodex {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path), "Opt-in Goal verification requires an authenticated guest Codex home.")
        }
        launchApp(defaultParent: self.fixture.parent.path)
        try createTaskFixture(title: "Durable goal", roots: [self.fixture.primary.path])
        let taskID = try taskID(named: "Durable goal")
        let objective = "Write a short two-line song about a dog, mark this Goal complete, and finish the task with no follow-up needed."
        if !usesLiveCodex {
            _ = try runCLI(["conversation", "goal", taskID, "set", "--text", objective])
            _ = try runCLI(["conversation", "goal", taskID, "pause"])
        }
        openTask(named: "Durable goal")

        if !usesLiveCodex {
            let row = element("active-goal-progress-row")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
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
            XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 5))
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
            openTask(named: "Durable goal")
            let replacementRow = element("active-goal-progress-row")
            XCTAssertTrue(replacementRow.waitForExistence(timeout: 10), "A replacement Goal should be restored after a CLI/XPC set.")
            XCTAssertTrue(accessibleLabelOrValue(of: element("active-goal-title")).contains(replacementObjective))
            let replacementTimer = element("goal-elapsed-time")
            XCTAssertTrue(replacementTimer.waitForExistence(timeout: 10))
            let replacementTimerText = accessibleLabelOrValue(of: replacementTimer)
            let replacementSeconds = Int(replacementTimerText.replacingOccurrences(of: "s", with: ""))
            XCTAssertNotNil(replacementSeconds, "Expected a replacement Goal timer in seconds, got: \(replacementTimerText)")
            XCTAssertLessThanOrEqual(replacementSeconds ?? Int.max, 5, "A Goal created after clearing should not inherit the cleared Goal's time.")
            element("goal-clear-button").click()
            XCTAssertTrue(waitUntil({ !self.element("active-goal-progress-row").exists }, timeout: 5))
            app.terminate()
            launchApp(defaultParent: fixture.parent.path)
            openTask(named: "Durable goal")
            XCTAssertTrue(waitUntil({ !self.element("active-goal-progress-row").exists }, timeout: 10), "A cleared Goal must stay cleared after reopening the task.")
            return
        }

        let composer = element("message-composer")
        composer.click()
        composer.typeText("/goal")
        let modeMenu = element("conversation-mode-menu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(modeMenu.label.contains("Goal"))
        element("send-message-button").click()
        XCTAssertTrue(element("codex-chat-error").waitForExistence(timeout: 5), "Blank Goal text should show a validation error.")
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
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil({
            self.element("goal-achieved-banner").exists
                || row.value as? String == "Work started"
                || row.value as? String == "Working"
        }, timeout: 30), "Submitting a Goal should start a Codex work turn, not only save the objective.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "In Progress")
        let conversationScrollView = element("conversation-scroll-view")
        let achievedBanner = conversationScrollView.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(achievedBanner.waitForExistence(timeout: 180), "Codex should replace the active Goal row with an achieved summary after completing the objective.")
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
            "stationai.codex.goal-achievement-timeline.\(taskID)",
            "stationai.codex.goal-generation.\(taskID)",
            "stationai.codex.goal-generation-objective.\(taskID)",
            "stationai.codex.goal-generation-time-baseline.\(taskID)",
        ].forEach { isolatedPreferences.removeObject(forKey: $0) }
        app.terminate()
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Durable goal")
        let migratedConversation = element("conversation-scroll-view")
        let migratedBanner = migratedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(migratedBanner.waitForExistence(timeout: 10), "A completed Goal created before timing metadata existed should be reconstructed from Codex history.")
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
        XCTAssertTrue(followupMessage.waitForExistence(timeout: 10), "The follow-up question should appear in the conversation.")
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
        modeMenu.click()
        app.menuItems["conversation-mode-goal"].click()
        composer.click()
        composer.typeText(secondObjective)
        element("send-message-button").click()
        let secondGoalTimer = element("goal-elapsed-time")
        XCTAssertTrue(secondGoalTimer.waitForExistence(timeout: 10), "A new Goal should show its own elapsed timer.")
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
        XCTAssertTrue(archiveButton.waitForExistence(timeout: 10))
        archiveButton.click()
        let archivedGoal = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archivedGoal.waitForExistence(timeout: 10), "The completed Goal task should be available in the Done archive.")
        archivedGoal.click()
        XCTAssertTrue(element("archived-conversation-read-only").waitForExistence(timeout: 10))
        let reopenedConversation = element("conversation-scroll-view")
        let restoredBanner = reopenedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achieved-banner").firstMatch
        XCTAssertTrue(restoredBanner.waitForExistence(timeout: 10), "A completed Goal should remain visible in the read-only conversation after archiving its task.")
        XCTAssertTrue(accessibleLabelOrValue(of: restoredBanner).contains("Goal achieved in"))
        let restoredAchievementRows = reopenedConversation.descendants(matching: .any)
            .matching(identifier: "goal-achievement-timeline-row")
        XCTAssertEqual(restoredAchievementRows.count, 2, "Both completed Goal events should remain in the archived conversation.")
        XCTAssertTrue(reopenedConversation.scrollBars.firstMatch.waitForExistence(timeout: 5), "The archived Goal transcript should expose scrolling when its conversation overflows.")
        let secondAchievementYBeforeScroll = restoredAchievementRows.element(boundBy: 1).frame.minY
        reopenedConversation.swipeDown()
        XCTAssertTrue(waitUntil({
            abs(restoredAchievementRows.element(boundBy: 1).frame.minY - secondAchievementYBeforeScroll) > 8
        }, timeout: 5), "Scrolling the conversation should move the Goal achievement with the transcript.")
        let restoredFollowup = reopenedConversation.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", followupPrompt)).firstMatch
        let restoredSecondAchievement = restoredAchievementRows.element(boundBy: 1)
        let restoredFirstAchievement = restoredAchievementRows.element(boundBy: 0)
        XCTAssertTrue(restoredFollowup.waitForExistence(timeout: 10))
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

    // case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer shows a Codex-reported model, while unsupported modes and malformed model IDs are rejected before creating history.
    func test_conversation_mode_rejects_unknown_mode_without_starting_a_turn() throws {
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Conversation modes", roots: [fixture.primary.path])
        openTask(named: "Conversation modes")

        let taskID = try taskID(named: "Conversation modes")
        let modelResult = try runCLI(["conversation", "models", taskID])["result"] as? [String: Any]
        let availableModels = try XCTUnwrap(modelResult?["models"] as? [[String: Any]])
        XCTAssertFalse(availableModels.isEmpty)
        let modelPicker = app.popUpButtons.firstMatch
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5), "The composer should expose a model returned by Codex.")
        func displayedModelValue() -> String {
            let rawValue = modelPicker.value as? String ?? modelPicker.label
            return String(rawValue.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let selectedModel = try XCTUnwrap(availableModels.first { model in
            let displayedModel = displayedModelValue()
            return displayedModel.caseInsensitiveCompare(model["name"] as? String ?? "") == .orderedSame
                || displayedModel.caseInsensitiveCompare(model["id"] as? String ?? "") == .orderedSame
        }, "The composer should expose a model returned by Codex.")
        let selectedModelName = try XCTUnwrap(selectedModel["name"] as? String)
        let selectedModelID = try XCTUnwrap(selectedModel["id"] as? String)
        let modelMenu = modelPicker
        XCTAssertTrue(displayedModelValue().caseInsensitiveCompare(selectedModelName) == .orderedSame
            || displayedModelValue().caseInsensitiveCompare(selectedModelID) == .orderedSame)
        if let alternateModel = availableModels.first(where: { $0["id"] as? String != selectedModelID }) {
            let alternateID = try XCTUnwrap(alternateModel["id"] as? String)
            modelMenu.click()
            let optionID = "model-option-\(alternateID)"
            let modelOption = app.menuItems.matching(identifier: optionID).firstMatch
            XCTAssertTrue(modelOption.waitForExistence(timeout: 5), "The model picker should list each model returned by Codex.")
            modelOption.click()
            let alternateName = alternateModel["name"] as? String ?? alternateID
            XCTAssertTrue(waitUntil({
                let displayedModel = displayedModelValue()
                return displayedModel.caseInsensitiveCompare(alternateName) == .orderedSame
                    || displayedModel.caseInsensitiveCompare(alternateID) == .orderedSame
            }, timeout: 5), "Choosing a model should update the composer selection.")
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

    // case-contract: test_codex_questions_can_be_answered_over_cli_xpc | MCP tool/requestUserInput structured questions raised in Plan mode use the existing question path, move the task into the conditional Waiting Response board section even when Codex marks the request non-blocking; reopening preserves its status, keyed answers resume In Progress, and the answered turn returns to Waiting Response without an explicit completed outcome.
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
            if completedStatus == "Waiting Response" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(completedStatus, "Waiting Response", "Without an explicit completed outcome, the submitted answer should leave the task in Waiting Response.")
        XCTAssertFalse(element("ai-question-form-title").exists)
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        assertTaskVisible("Codex questions", inColumn: "Waiting Response")
    }

    // case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section, and the successful retry returns to Waiting Response without an explicit completed outcome.
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
        XCTAssertEqual(try taskRecord(named: "Empty Codex questions")?["status"] as? String, "Waiting Response")
        XCTAssertTrue(waitForDisappearance(element("column-heading-blocked")), "The blocked section should disappear after the task is unblocked.")
        XCTAssertFalse(element("blocked-waiting-indicator").exists)
        assertTaskVisible("Empty Codex questions", inColumn: "Waiting Response")
    }

    // case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions remain visible without moving the task out of In Progress, then the answered turn returns to Waiting Response without an explicit completed outcome.
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
        XCTAssertEqual(try taskRecord(named: "Non-blocking question")?["status"] as? String, "Waiting Response")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 5))
        assertTaskVisible("Non-blocking question", inColumn: "Waiting Response")
    }

    // case-contract: test_codex_async_questions_render_and_reply_as_followup | Async agentMessage questions retain choices and a free-text prompt in live updates and fresh CLI/XPC history, stay separate from later assistant text, and receive validated answers through the shared manager during and after an active turn. The UI shows inline answer cards instead of raw bullet text, blocks incomplete answers, preserves answered cards across reopening, and displays both submitted answers and responses.
    func test_codex_async_questions_render_and_reply_as_followup() throws {
        let created = try runCLI(["task", "create", "--title", "Async Codex question", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        codexFixtureExecutable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question").path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Async Codex question")
        element("message-composer").click()
        element("message-composer").typeText("Ask an async question.")
        element("send-message-button").click()

        let card = element("async-question-item_stationai_async_question")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let yesOption = element("async-question-option-item_stationai_async_question-0-0")
        let noOption = element("async-question-option-item_stationai_async_question-0-1")
        XCTAssertEqual(yesOption.label, "Yes, update paired tests and run required verification")
        XCTAssertEqual(noOption.label, "No, leave tests and verification for later")
        XCTAssertTrue(element("async-question-answer-item_stationai_async_question-1").exists)
        XCTAssertFalse(element("assistant-message-item_stationai_async_question").exists,
                       "Structured choices should appear in an answer card instead of a Markdown bubble.")
        XCTAssertFalse(element("submit-async-questions-item_stationai_async_question").isEnabled)
        XCTAssertTrue(app.staticTexts["I can continue while you decide."].waitForExistence(timeout: 10),
                      "The assistant message after the question must remain separate.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question.question-ready").path),
                      "The question fixture must still have an active turn.")
        yesOption.click()
        XCTAssertFalse(element("submit-async-questions-item_stationai_async_question").isEnabled,
                       "Every async question needs an answer before submission.")
        let detail = element("async-question-answer-item_stationai_async_question-1")
        detail.click()
        detail.typeText("Keep the draft intact.")
        let composer = element("message-composer")
        composer.click()
        composer.typeText("An unsent draft stays here.")
        element("submit-async-questions-item_stationai_async_question").click()

        let reply = "Test and verify: Yes, update paired tests and run required verification\nAdditional detail: Keep the draft intact."
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 10), "The full two-answer reply must be sent.")
        let response = element("assistant-message-item_stationai_async_answer_steered")
        XCTAssertTrue(response.waitForExistence(timeout: 10))
        XCTAssertTrue(response.label.contains("Answers received: Test and verify: Yes, update paired tests and run required verification"))
        XCTAssertTrue(response.label.contains("Additional detail: Keep the draft intact."))
        XCTAssertTrue(card.exists)
        XCTAssertTrue(app.staticTexts["Answered"].exists)
        XCTAssertEqual(composer.value as? String, "An unsent draft stays here.")
        let laterCard = element("async-question-item_stationai_async_later_question")
        XCTAssertTrue(laterCard.waitForExistence(timeout: 10))
        let idleDeadline = Date().addingTimeInterval(10)
        while !element("send-message-button").isEnabled && Date() < idleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(element("send-message-button").isEnabled, "The later answer must be submitted after the first turn completes.")
        let laterAnswer = element("async-question-answer-item_stationai_async_later_question-0")
        laterAnswer.click()
        laterAnswer.typeText("Finish after the turn.")
        element("submit-async-questions-item_stationai_async_later_question").click()
        let completedResponse = element("assistant-message-item_stationai_async_answer_2")
        XCTAssertTrue(completedResponse.waitForExistence(timeout: 10),
                      "A question answered after its original turn must refresh the visible conversation.")
        XCTAssertTrue(completedResponse.label.contains("Answers received: One more check: Finish after the turn."))
        XCTAssertEqual(composer.value as? String, "An unsent draft stays here.")
        element("back-to-board-button").click()
        openTask(named: "Async Codex question")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Answered"].exists)
        XCTAssertTrue(laterCard.exists)
        XCTAssertTrue(laterCard.staticTexts["Answered"].exists, "The later question must stay answered after reopening.")
        XCTAssertEqual(element("message-composer").value as? String, "An unsent draft stays here.")
    }

    // case-contract: test_codex_async_question_queued_answer_retries | An async question answered after its turn ends stays Pending when the first follow-up fails, rejects duplicate answers across fresh CLI/XPC connections, and becomes Answered only after an explicit queued retry succeeds. The paired UI keeps the card and queue action visible across reopening and then displays the delivered response.
    func test_codex_async_question_queued_answer_retries() throws {
        let created = try runCLI(["task", "create", "--title", "Queued async question", "--root", fixture.primary.path])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let executable = WorkspaceFixture.root.appendingPathComponent("codex-fixture-async-question-queued")
        codexFixtureExecutable = executable.path
        launchApp(defaultParent: fixture.parent.path)
        openTask(named: "Queued async question")
        element("message-composer").click()
        element("message-composer").typeText("Ask a queued async question.")
        element("send-message-button").click()
        let card = element("async-question-item_stationai_async_question")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil({
            ((try? self.taskRecord(id: taskID))?["status"] as? String) == "Waiting Response"
        }, timeout: 10), "The first turn must finish before queueing the answer.")
        _ = FileManager.default.createFile(atPath: executable.path + ".fail-next-turn-start", contents: Data())
        element("async-question-option-item_stationai_async_question-0-0").click()
        element("async-question-answer-item_stationai_async_question-1").click()
        element("async-question-answer-item_stationai_async_question-1").typeText("Retry this answer.")
        element("submit-async-questions-item_stationai_async_question").click()
        XCTAssertTrue(card.staticTexts["Pending"].waitForExistence(timeout: 10))
        let queueResult = try runCLI(["conversation", "queue-list", taskID])
        let queued = try XCTUnwrap((queueResult["result"] as? [[String: Any]])?.first)
        XCTAssertEqual(queued["asyncQuestionItemID"] as? String, "item_stationai_async_question")
        let queuedID = try XCTUnwrap(queued["id"] as? String)
        XCTAssertEqual(queued["state"] as? String, "needsAction")
        element("back-to-board-button").click()
        openTask(named: "Queued async question")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts["Pending"].exists)
        let retry = element("retry-queued-message-\(queuedID.uppercased())")
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        let response = element("assistant-message-item_stationai_async_answer_2")
        XCTAssertTrue(response.waitForExistence(timeout: 10))
        XCTAssertTrue(response.label.contains("Answers received: Test and verify: Yes, update paired tests and run required verification"))
        XCTAssertTrue(response.label.contains("Additional detail: Retry this answer."))
        XCTAssertTrue(card.staticTexts["Answered"].exists)
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
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Interrupted turn", prompt: "Retry the interrupted task.")
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

    private var isLiveCodexIntegration: Bool {
        ProcessInfo.processInfo.environment["STATIONAI_RUN_CODEX_INTEGRATION"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/stationai-codex-live-ui-integration")
    }

    private func launchApp(defaultParent: String?, environmentOverrides: [String: String] = [:]) {
        clearSavedWindowFrames()
        launchDefaultParent = defaultParent
        let bundleIdentifier = Bundle(url: appBundle)?.bundleIdentifier ?? "com.stationai.app.e2e"
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        app.launchEnvironment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        app.launchEnvironment["CODEX_HOME"] = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        app.launchEnvironment["STATIONAI_WORKTREE_LABEL"] = "StationAI UI Test Worktree"
        app.launchEnvironment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        app.launchEnvironment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        app.launchEnvironment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = defaultParent ?? "__unset__"
        if let launchWindowTitle {
            app.launchEnvironment["STATIONAI_WINDOW_TITLE"] = launchWindowTitle
        }
        if let codexFixtureExecutable {
            app.launchEnvironment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        }
        for (key, value) in environmentOverrides {
            app.launchEnvironment[key] = value
        }
        launchAppWithOpen(bundleIdentifier: bundleIdentifier, environmentOverrides: environmentOverrides)
        waitForBoardOrAbortSuite()
        let newTaskButton = element("new-task-button")
        if newTaskButton.exists && !newTaskButton.isHittable {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            windowMenu.click()
            let zoom = app.menuItems["Zoom"]
            if zoom.waitForExistence(timeout: 2) {
                zoom.click()
            } else {
                app.typeKey("z", modifierFlags: [.command, .option])
            }
            app.activate()
        }
    }


    private func launchAppWithOpen(bundleIdentifier: String? = nil, environmentOverrides: [String: String] = [:]) {
        let targetBundleIdentifier = bundleIdentifier ?? Bundle(url: appBundle)?.bundleIdentifier ?? "com.stationai.app.e2e"
        var environment = ProcessInfo.processInfo.environment
        environment["STATIONAI_DATA_DIRECTORY"] = dataDirectory.path
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let codexHome = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        environment["CODEX_HOME"] = codexHome
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] = launchDefaultParent ?? "__unset__"
        if let launchWindowTitle {
            environment["STATIONAI_WINDOW_TITLE"] = launchWindowTitle
        }
        if let codexFixtureExecutable {
            environment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        }
        environment.merge(environmentOverrides, uniquingKeysWith: { _, new in new })
        app = XCUIApplication(bundleIdentifier: targetBundleIdentifier)
        app.launchEnvironment = environment
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [
            "-n",
            "--env", "STATIONAI_DATA_DIRECTORY=\(dataDirectory.path)",
            "--env", "CODEX_HOME=\(codexHome)",
            "--env", "STATIONAI_WORKTREE_LABEL=StationAI UI Test Worktree",
            "--env", "STATIONAI_E2E_WORKTREE_DIRECTORY=\(dataDirectory.appendingPathComponent("worktrees").path)",
            "--env", "STATIONAI_E2E_DEFAULTS_SUITE=\(preferencesSuiteName!)",
            "--env", "STATIONAI_E2E_DEFAULT_PARENT_FOLDER=\(launchDefaultParent ?? "__unset__")"
        ]
        if usesLiveCodex {
            opener.arguments?.append(contentsOf: ["--env", "STATIONAI_RUN_CODEX_INTEGRATION=1"])
        }
        if let launchWindowTitle {
            opener.arguments?.append(contentsOf: ["--env", "STATIONAI_WINDOW_TITLE=\(launchWindowTitle)"])
        }
        if let codexFixtureExecutable {
            opener.arguments?.append(contentsOf: ["--env", "STATIONAI_E2E_CODEX_EXECUTABLE=\(codexFixtureExecutable)"])
        }
        for (key, value) in environmentOverrides {
            opener.arguments?.append(contentsOf: ["--env", "\(key)=\(value)"])
        }
        opener.arguments?.append(appBundle.path)
        let output = Pipe()
        opener.standardOutput = output
        opener.standardError = output
        do {
            try opener.run()
            opener.waitUntilExit()
        } catch {
            XCTFail("Could not start the StationAI LaunchServices request: \(error.localizedDescription)")
            return
        }
        let launchOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(opener.terminationStatus, 0, "Could not start StationAI through LaunchServices: \(launchOutput)")
        app.activate()
    }

    private func waitForBoardOrAbortSuite() {
        let boardTitle = element("board-title")
        if waitUntil({ self.isStationAIFrontmost }, timeout: 3),
           boardTitle.waitForExistence(timeout: 6) {
            return
        }

        let relaunchedAfterMissingWindow: Bool
        if terminateAppAndWait(app, timeout: 8) {
            launchAppWithOpen()
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

    private func makeGitHubStateFixture() throws -> [String: String] {
        try makeGitHubStateFixture(expectedNumbers: [123, 456])
    }

    private func makeGitHubStateFixture(expectedNumbers: [Int]) throws -> [String: String] {
        let directory = dataDirectory.appendingPathComponent("gh-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state")
        let callLogURL = directory.appendingPathComponent("calls")
        try expectedNumbers.map { "\($0)=unmerged" }.joined(separator: "\n").appending("\n")
            .write(to: stateURL, atomically: true, encoding: .utf8)
        let startedDirectory = directory.appendingPathComponent("started", isDirectory: true)
        try FileManager.default.createDirectory(at: startedDirectory, withIntermediateDirectories: true)
        let expectedIDs = expectedNumbers.map(String.init).joined(separator: " ")
        let executable = directory.appendingPathComponent("gh")
        let script = """
        #!/bin/sh
        if [ "$1" != pr ] || [ "$2" != view ] || { [ "$3" != 123 ] && [ "$3" != 456 ]; } || [ "$4" != --json ]; then
          echo 'Unexpected gh fixture command' >&2
          exit 2
        fi
        printf '%s\\n' "$3" >> "$STATIONAI_E2E_GH_CALL_LOG"
        state=$(awk -F= -v number="$3" '$1 == number { print $2 }' "$STATIONAI_E2E_GH_STATE_PATH")
        if [ "$5" = mergedAt ]; then
          if [ "$state" = merged ]; then
            printf '{"mergedAt":"2026-10-22T00:00:00Z"}\\n'
          else
            printf '{"mergedAt":null}\\n'
          fi
        elif [ "$5" = mergedAt,mergeable,headRefOid ]; then
          touch "$STATIONAI_E2E_GH_STARTED_DIRECTORY/$3"
          parallel=0
          for attempt in $(seq 1 100); do
            parallel=1
            for expected in $STATIONAI_E2E_GH_EXPECTED_IDS; do
              if [ ! -f "$STATIONAI_E2E_GH_STARTED_DIRECTORY/$expected" ]; then parallel=0; fi
            done
            [ "$parallel" = 1 ] && break
            sleep 0.02
          done
          if [ "$parallel" != 1 ]; then echo 'Review pull request probes did not run in parallel' >&2; exit 3; fi
          if [ -n "$STATIONAI_E2E_GH_REMOTE_REPOSITORY" ]; then
            head=$(git --git-dir "$STATIONAI_E2E_GH_REMOTE_REPOSITORY" rev-parse "refs/heads/pr-$3")
          else
            head=$(git rev-parse HEAD)
          fi
          if [ "$state" = head-mismatch ]; then
            printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"remote-head-not-pushed"}\\n'
          elif [ "$state" = merged ]; then
            printf '{"mergedAt":"2026-10-22T00:00:00Z","mergeable":"MERGEABLE","headRefOid":"%s"}\\n' "$head"
          elif [ "$state" = conflicting ]; then
            printf '{"mergedAt":null,"mergeable":"CONFLICTING","headRefOid":"%s"}\\n' "$head"
          else
            printf '{"mergedAt":null,"mergeable":"MERGEABLE","headRefOid":"%s"}\\n' "$head"
          fi
        else
          echo 'Unexpected gh fixture field list' >&2
          exit 2
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return [
            "PATH": "\(directory.path):\(inheritedPath)",
            "STATIONAI_E2E_GH_STATE_PATH": stateURL.path,
            "STATIONAI_E2E_GH_CALL_LOG": callLogURL.path,
            "STATIONAI_E2E_GH_STARTED_DIRECTORY": startedDirectory.path,
            "STATIONAI_E2E_GH_EXPECTED_IDS": expectedIDs,
        ]
    }

    private func activateOtherAppThenReturn() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        app.activate()
    }

    private func relaunchApp() {
        XCTAssertTrue(terminateAppAndWait(app), "StationAI must stop before the resume-path relaunch.")
        launchAppWithOpen()
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
        let repositorySearch = element("conversation-repository-search")
        XCTAssertTrue(repositorySearch.waitForExistence(timeout: 10), "A new conversation should open its repository picker.")
        repositorySearch.click()
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
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitForExistence(timeout: 10), "Returning to the board should preserve the automatically saved prompt.")
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

    private func chooseRepositorySuggestion(_ name: String) {
        var searchField = element("conversation-repository-search")
        if !searchField.exists {
            element("add-conversation-repository-button").click()
            searchField = element("conversation-repository-search")
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "The conversation picker should be open before choosing a repository.")
        searchField.click()
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

    private func completeCurrentTaskWithFixtureAnswers(taskTitle: String, prompt: String = "Complete this task.") throws {
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
        XCTAssertTrue(element("ai-question-form-title").waitForExistence(timeout: 10))
        app.buttons["Blue"].click()
        element("ai-question-answer-token").click()
        element("ai-question-answer-token").typeText("fixture-secret")
        element("submit-ai-answers-button").click()
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: active.path) }, timeout: 10), "The fixture should hold after receiving answers so the task outcome can be reported.")
        let outcome = try runCLI(["task", "outcome", taskID, "completed"])
        XCTAssertEqual((outcome["result"] as? [String: Any])?["outcome"] as? String, "completed")
        try "Release the answered fixture turn.\n".write(to: release, atomically: true, encoding: .utf8)
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

    private func assertContainsRedForeground(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the missing-folder warning screenshot.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var redPixels = 0
        for x in stride(from: 0, to: cgImage.width, by: 2) {
            for y in stride(from: 0, to: cgImage.height, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.65 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(redPixels, 3, "The missing-folder warning should render red foreground pixels.", file: file, line: line)
    }

    private func assertStationAILogoArtwork(_ element: XCUIElement, in window: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let logoImage = element.screenshot().image
        guard let cgImage = logoImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let windowCGImage = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the StationAI logo screenshot.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        assertPixel(logoImage, normalizedX: 0.2, normalizedY: 0.5, rgb: (61, 125, 214), accuracy: 55, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.5, normalizedY: 0.65, rgb: (115, 86, 184), accuracy: 55, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.82, normalizedY: 0.55, rgb: (38, 161, 108), accuracy: 55, file: file, line: line)
        assertPixel(logoImage, normalizedX: 0.77, normalizedY: 0.78, rgb: (254, 158, 71), accuracy: 55, file: file, line: line)

        let windowBitmap = NSBitmapImageRep(cgImage: windowCGImage)
        let logoFrame = element.frame
        let windowFrame = window.frame
        let corners: [(logo: CGPoint, background: CGPoint)] = [
            (CGPoint(x: 0.02, y: 0.02), CGPoint(x: logoFrame.minX - 2, y: logoFrame.minY + 2)),
            (CGPoint(x: 0.98, y: 0.02), CGPoint(x: logoFrame.maxX + 2, y: logoFrame.minY + 2)),
            (CGPoint(x: 0.02, y: 0.98), CGPoint(x: logoFrame.minX - 2, y: logoFrame.maxY - 2)),
            (CGPoint(x: 0.98, y: 0.98), CGPoint(x: logoFrame.maxX + 2, y: logoFrame.maxY - 2)),
            (CGPoint(x: 0.30, y: 0.50), CGPoint(x: logoFrame.minX - 2, y: logoFrame.minY + logoFrame.height * 0.50))
        ]
        for corner in corners {
            let headerPoint = CGPoint(
                x: (corner.background.x - windowFrame.minX) / windowFrame.width,
                y: (corner.background.y - windowFrame.minY) / windowFrame.height
            )
            guard let logoColor = color(in: bitmap, normalizedPoint: corner.logo),
                  let backgroundColor = color(in: windowBitmap, normalizedPoint: headerPoint) else {
                XCTFail("Could not sample the logo's transparent corners and adjacent window background.", file: file, line: line)
                return
            }
            XCTAssertEqual(logoColor.redComponent, backgroundColor.redComponent, accuracy: 0.04, "The logo's transparent corner should reveal the adjacent window background.", file: file, line: line)
            XCTAssertEqual(logoColor.greenComponent, backgroundColor.greenComponent, accuracy: 0.04, "The logo's transparent corner should reveal the adjacent window background.", file: file, line: line)
            XCTAssertEqual(logoColor.blueComponent, backgroundColor.blueComponent, accuracy: 0.04, "The logo's transparent corner should reveal the adjacent window background.", file: file, line: line)
        }
    }

    private func color(in bitmap: NSBitmapImageRep, normalizedPoint: CGPoint) -> NSColor? {
        let x = min(bitmap.pixelsWide - 1, max(0, Int(CGFloat(bitmap.pixelsWide) * normalizedPoint.x)))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int(CGFloat(bitmap.pixelsHigh) * normalizedPoint.y)))
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }

    private func assertSubagentIconArtwork(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the subagent icon screenshot.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func colorAt(_ normalizedX: CGFloat, _ normalizedY: CGFloat) -> NSColor? {
            let x = min(cgImage.width - 1, max(0, Int(CGFloat(cgImage.width) * normalizedX)))
            let y = min(cgImage.height - 1, max(0, Int(CGFloat(cgImage.height) * normalizedY)))
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }
        guard let topCyan = colorAt(0.5125, 0.2125),
              let leftEye = colorAt(0.3625, 0.4875),
              let face = colorAt(0.5125, 0.5125),
              let lowerLeftAccent = colorAt(0.2125, 0.7875) else {
            XCTFail("Could not sample the subagent icon artwork.", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(topCyan.greenComponent, 0.65, "The robot's top cyan detail should render at its expected position.", file: file, line: line)
        XCTAssertGreaterThan(topCyan.blueComponent, 0.65, "The robot's top cyan detail should render at its expected position.", file: file, line: line)
        XCTAssertLessThan(topCyan.redComponent, 0.5, "The top detail should retain the icon's cyan color.", file: file, line: line)
        XCTAssertGreaterThan(leftEye.blueComponent, leftEye.redComponent * 1.4, "A blue eye should appear at the expected left-eye position.", file: file, line: line)
        XCTAssertGreaterThan(face.blueComponent, face.redComponent * 1.4, "The robot face should appear at the center of the icon.", file: file, line: line)
        XCTAssertGreaterThan(lowerLeftAccent.blueComponent, lowerLeftAccent.redComponent * 1.15, "The lower-left orbit should retain the icon's purple accent.", file: file, line: line)
        XCTAssertGreaterThan(lowerLeftAccent.redComponent, lowerLeftAccent.greenComponent * 1.05, "The lower-left orbit should retain the icon's purple accent.", file: file, line: line)
    }

    private func assertContainsGreenForeground(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the merged-PR completion button screenshot.", file: file, line: line)
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var greenPixels = 0
        for x in stride(from: 0, to: cgImage.width, by: 1) {
            for y in stride(from: 0, to: cgImage.height, by: 1) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.greenComponent > 0.35,
                   color.redComponent < 0.65,
                   color.blueComponent < 0.65,
                   color.greenComponent > color.redComponent * 1.15,
                   color.greenComponent > color.blueComponent * 1.05 {
                    greenPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(greenPixels, 3, "The merged-PR completion checkmark should render green foreground pixels.", file: file, line: line)
    }

    private func deleteTaskFromContextMenu(_ title: String) {
        let card = app.buttons[title].firstMatch
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
        pathField.typeText(file.standardizedFileURL.path)
        pathField.typeKey(.return, modifierFlags: [])
        if !goToSheet.waitForNonExistence(timeout: 2) {
            let target = panel.descendants(matching: .any).matching(
                NSPredicate(format: "value == %@ OR label == %@", file.lastPathComponent, file.lastPathComponent)
            ).firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 10), "The image picker should select the full path.")
        }
        guard panel.exists else { return }
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

    private func seedTaskPullRequest(taskID: String, number: Int, url: String, repositoryIndex: Int = 0) throws {
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
        let usesLiveCodex = isLiveCodexIntegration
        let liveCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        environment["CODEX_HOME"] = usesLiveCodex ? liveCodexHome : dataDirectory.appendingPathComponent("codex-home").path
        environment["STATIONAI_E2E_WORKTREE_DIRECTORY"] = dataDirectory.appendingPathComponent("worktrees").path
        environment["STATIONAI_E2E_DEFAULTS_SUITE"] = preferencesSuiteName
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = serviceName
        if let codexFixtureExecutable {
            environment["STATIONAI_E2E_CODEX_EXECUTABLE"] = codexFixtureExecutable
        }
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
        XCTAssertTrue(helpTag.waitForExistence(timeout: 8), "Expected the hovered control to show the help tag ‘\(expected)’." )
    }

    private func assertHoverEmphasis(for element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let before = element.screenshot().image
        // XCTest cannot read NSCursor.current from the app process; hover inside the padded edge to verify that region receives hover events.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 0.2)
        let after = element.screenshot().image
        guard let beforeCG = before.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let afterCG = after.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read control screenshots to verify hover emphasis.", file: file, line: line)
            return
        }
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

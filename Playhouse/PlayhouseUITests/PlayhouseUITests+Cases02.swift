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
    // case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | Adding a repository branch already assigned to another active task is rejected in the new conversation, and the existing task and repository reservation remain unchanged.
    func test_task_creation_rejects_worktree_assigned_to_active_task() throws {
        launchApp(defaultParent: fixture.parent.path)
        let branch = "active-shared-\(UUID().uuidString.prefix(8).lowercased())"
        let owner = try XCTUnwrap(try runCLI(["task", "create", "--title", "Active owner", "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--branch", "\(fixture.primary.path)=\(branch)"])["result"] as? [String: Any])
        let ownerID = try XCTUnwrap(owner["id"] as? String)
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        let newTask = try XCTUnwrap(tasksFromBoardList().first { $0["id"] as? String != ownerID })
        let newTaskID = try XCTUnwrap(newTask["id"] as? String)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 5))
        badge.click()
        element("conversation-repository-branch-edit").click()
        let branchField = element("conversation-repository-branch")
        replaceText(branchField, with: branch)
        element("conversation-repository-branch-save").click()
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 10))
        let errorText = error.label + (error.value as? String ?? "")
        XCTAssertTrue(errorText.contains("is already used by task \"Active owner\""), errorText)
        XCTAssertTrue(errorText.contains("`\(branch)`"), errorText)
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
                "task", "create", "--title", title, "--prompt", "Fixture task description.",
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
        XCTAssertTrue(((rejected["error"] as? [String: Any])?["message"] as? String ?? "").contains("is already used by task"))

        let tasks = try tasksFromBoardList()
        XCTAssertEqual(tasks.count, 1)
        let taskID = try XCTUnwrap(tasks.first?["id"] as? String)
        let record = try XCTUnwrap((taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["branch"] as? String, branch)
        XCTAssertEqual(record["isPending"] as? Bool, true)
        let card = element("task-card-\(taskID.uppercased())")
        XCTAssertTrue(waitUntil({ card.exists }, timeout: 10), "Exactly one reservation should appear on the visible board.")
        clickTaskCardTitle(card)
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10))
    }
    // case-contract: test_persistence_store_open_failure_records_detailed_error | A real ModelContainer open failure against an isolated invalid store path returns an error and durably logs the phase, exact underlying NSError domain/code/userInfo, resolved store path, file/sidecar snapshot, and read-only schema probe failure; the paired visible UI case keeps Playhouse open on its normal board while the same isolated CLI/XPC request fails and verifies the persisted diagnostic.
    func test_persistence_store_open_failure_records_detailed_error() throws {
        launchApp(defaultParent: fixture.parent.path)
        let failureDirectory = dataDirectory.appendingPathComponent("invalid-store-open", isDirectory: true)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let store = failureDirectory.appendingPathComponent("Playhouse-v2.store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)

        let failedResponse = try runCLI(
            ["task", "list"],
            expectedStatus: 1,
            extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": failureDirectory.path]
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
        XCTAssertEqual(app.state, .runningForeground, "The normal Playhouse app should remain open after the isolated CLI failure.")
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5), "The normal board should remain visible after the isolated CLI failure.")
    }
    // case-contract: test_persistence_read_failure_records_detailed_error | A real SwiftData fetch failure against an isolated store with a missing task column returns an error and logs a correlated read ID, NSError domain/code/userInfo, store path, file/sidecar snapshot, and the exact missing-column message from a read-only schema probe before the CLI/XPC request completes; the paired visible UI case keeps the normal task board open and verifies the same isolated failure record.
    func test_persistence_read_failure_records_detailed_error() throws {
        launchApp(defaultParent: fixture.parent.path)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        let failureDirectory = dataDirectory.appendingPathComponent("fetch-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        _ = try runCLI(
            ["task", "create", "--title", "Missing column read failure", "--prompt", "Fixture task description.", "--root", fixture.primary.path],
            extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": failureDirectory.path]
        )
        let store = failureDirectory.appendingPathComponent("Playhouse-v2.store")
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
            extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": failureDirectory.path]
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
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5), "The normal app board should stay available while the isolated bridge store fails.")
    }
    // case-contract: test_legacy_store_import_failure_preserves_original | An invalid legacy database fails import without changing the source or publishing a destination or partial snapshot; the normal isolated board remains usable.
    func test_legacy_store_import_failure_preserves_original() throws {
        launchApp(defaultParent: fixture.parent.path)
        let failure = dataDirectory.appendingPathComponent("invalid-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: failure, withIntermediateDirectories: true)
        let source = failure.appendingPathComponent("Playhouse.store")
        let contents = Data("Not a SQLite database".utf8)
        try contents.write(to: source)
        let response = try runCLI(["task", "list"], expectedStatus: 1, extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": failure.path])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.appendingPathComponent("Playhouse-v2.store").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: failure.path).contains { $0.hasPrefix(".store-import-") })
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element("board-title").waitToExist(timeout: 5))
        openNewTaskConversation()
        chooseRepositorySuggestion("primary")
        saveNewTaskPromptAndReturnToBoard("Healthy board", prompt: "Still usable")
        openTask(named: "Healthy board")
        XCTAssertEqual(element("message-composer").value as? String, "Still usable")
    }
    // case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with in-progress timing columns and no submitted-prompt column waits for the store-write lock while CLI/XPC reads concurrently; migration backs up before adding the missing VARCHAR prompt column as nullable with no default and preserves elapsed time at zero. The CLI preserves the task and its saved prompt, which a store from before drafts were flagged does not restore as a draft, and the visible app opens the migrated store with an empty composer that keeps the saved prompt through a subsequent restart with duration still zero; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only saved prompt data survives import, and a subsequent edited draft survives restart without reimport.
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
        let store = dataDirectory.appendingPathComponent("Playhouse-v2.store")
        let legacyStore = dataDirectory.appendingPathComponent("Playhouse.store")
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
            .filter { $0.lastPathComponent.hasPrefix("Playhouse.store.before-pending-prompt-") && $0.pathExtension == "backup" }
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
        XCTAssertEqual(Double(promptColumn[3]), 0.0)
        XCTAssertEqual(promptColumn[4], "")
        let durationColumn = try XCTUnwrap(
            migratedColumnRows.first { $0.count >= 6 && $0[1] == "ZTOTALINPROGRESSSECONDS" }
        )
        XCTAssertEqual(durationColumn[2], "FLOAT")
        XCTAssertEqual(Double(durationColumn[3]), 0.0)
        XCTAssertEqual(durationColumn[4], "")
        XCTAssertEqual(
            Double(try sqlite("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK", at: store).trimmingCharacters(in: .whitespacesAndNewlines)),
            0.0
        )
        XCTAssertNotEqual(try sqlite("SELECT hex(Z_PLIST) FROM Z_METADATA", at: store), legacyMetadata)
        XCTAssertEqual(try Data(contentsOf: legacyStore), legacyBytes)
        let migrationEvents = try diagnosticEvents()
        XCTAssertTrue(migrationEvents.contains { $0["event"] as? String == "persistence.store.schema_migration.write_lock_acquired" })
        XCTAssertFalse(migrationEvents.contains {
            ["persistence.store.open.failed", "persistence.read.failed"].contains($0["event"] as? String ?? "")
        })
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, draft)
        openTask(named: title)
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10), "The migrated task should open its composer.")
        // The draft restores asynchronously after history loads, so hold the empty composer for a moment.
        XCTAssertFalse(waitUntil({
            !((element("message-composer").value as? String) ?? "").isEmpty
        }, timeout: 2), "A store from before drafts were flagged does not restore its saved prompt as a draft.")
        XCTAssertTrue(terminateAppAndWait(app))
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible(title, inColumn: "Backlog")
        openTask(named: title)
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10), "The migrated task should reopen its composer after a restart.")
        XCTAssertFalse(waitUntil({
            !((element("message-composer").value as? String) ?? "").isEmpty
        }, timeout: 2), "The saved prompt should stay out of the composer after a restart.")
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, draft, "The saved prompt should survive the restart in the store.")
        attachScreenshot(named: "Migrated store opens with an empty composer and keeps its saved prompt")

        let composer = element("message-composer")
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("Edited after import")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, "Edited after import")
        XCTAssertTrue(terminateAppAndWait(app))
        launchApp(defaultParent: fixture.parent.path)
        assertTaskVisible(title, inColumn: "Backlog")
        openTask(named: title)
        XCTAssertEqual(element("message-composer").value as? String, "Edited after import")
        XCTAssertEqual(
            Double(try sqlite("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK", at: store).trimmingCharacters(in: .whitespacesAndNewlines)),
            0.0
        )
        XCTAssertEqual(try diagnosticEvents().filter { $0["event"] as? String == "persistence.store.legacy_imported" }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Playhouse.store.before-pending-prompt-") && $0.pathExtension == "backup" }.count, 1)
    }
    // case-contract: test_test_bundle_rejects_unisolated_data_directory | A test-built Playhouse service rejects a data directory outside the temporary test area and a linked store inside it before creating or opening either store; the visible app remains on its isolated board and can still read its tasks.
    func test_test_bundle_rejects_unisolated_data_directory() throws {
        launchApp(defaultParent: fixture.parent.path)
        let title = "Isolated board remains available"
        let created = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description."])
        let taskID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        assertTaskVisible(title, inColumn: "Backlog")

        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let unsafe = caches.appendingPathComponent("Playhouse-bridge-guard-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.path))
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        let marker = unsafe.appendingPathComponent(".playhouse-test-owner")
        try "Playhouse bridge guard test (v1).\n".write(to: marker, atomically: true, encoding: .utf8)
        defer {
            if (try? String(contentsOf: marker, encoding: .utf8)) == "Playhouse bridge guard test (v1).\n" {
                try? FileManager.default.removeItem(at: unsafe)
            } else {
                XCTFail("Refusing to remove a guard fixture without its ownership marker.")
            }
        }
        let denied = try runCLI(
            ["board", "list"], expectedStatus: 1,
            extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": unsafe.path]
        )
        XCTAssertEqual(denied["error"] as? [String: String], [
            "code": "operation_failed",
            "message": "A Playhouse test bundle requires an isolated temporary data directory."
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("Playhouse-v2.store").path))
        let linked = dataDirectory.appendingPathComponent("linked-store", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("Playhouse-v2.store"),
            withDestinationURL: unsafe.appendingPathComponent("Playhouse-v2.store")
        )
        let linkedDenied = try runCLI(
            ["board", "list"], expectedStatus: 1,
            extraEnvironment: ["PLAYHOUSE_DATA_DIRECTORY": linked.path]
        )
        XCTAssertEqual(linkedDenied["error"] as? [String: String], [
            "code": "operation_failed",
            "message": "A Playhouse test bundle cannot open a linked task store."
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent("Playhouse-v2.store").path))
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
        _ = try runCLI(["settings", "set-parent", fixture.parent.path])
        let created = try XCTUnwrap(
            try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any]
        )
        let taskID = try XCTUnwrap(created["id"] as? String)
        codexFixtureExecutable = fixtureExecutable.path
        let prompt = "Persist this completed turn."
        let process = try startCLIProcess(
            ["conversation", "send", taskID, "--message", prompt],
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": fixtureExecutable.path]
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
            extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": fixtureExecutable.path]
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
        XCTAssertEqual(waitedWrite["storePath"] as? String, dataDirectory.appendingPathComponent("Playhouse-v2.store").path)
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
        let expectedStorePath = dataDirectory.appendingPathComponent("Playhouse-v2.store").path
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
        XCTAssertTrue(element("task-view-title").waitToExist(timeout: 10))
        let savedPrompt = app.textViews.matching(NSPredicate(format: "value == %@", prompt)).firstMatch
        XCTAssertTrue(savedPrompt.waitToExist(timeout: 10), "The saved user message should render after reopening the conversation.")
        let savedAnswer = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "assistant-message-",
                "Answers received: Blue / fixture-secret."
            )
        ).firstMatch
        XCTAssertTrue(savedAnswer.waitToExist(timeout: 10), "The saved assistant reply should render after reopening the conversation.")
        XCTAssertFalse(element("codex-chat-error").exists, "A recovered store write must not leave a conversation error banner.")
        attachScreenshot(named: "Conversation status and history persist after shared store contention")
    }
    // case-contract: test_task_worktree_preparation_serializes_auto_branch_claims | Tasks with the same automatic branch choice remain pending without creating a worktree before conversation start. When one task has claimed the generated branch, a send from the other (through the CLI) succeeds with its own suffixed branch and a separate worktree, leaving both tasks started; the opt-in live provider integration sends both turns concurrently and confirms each task gets a distinct branch and worktree.
    func test_task_worktree_preparation_serializes_auto_branch_claims() throws {
        launchApp(defaultParent: fixture.parent.path)
        let existingWorktreeCount = try runGitOutput(fixture.primary, "worktree", "list", "--porcelain")
            .components(separatedBy: "worktree ").count - 1
        let title = "Concurrent auto branch \(UUID().uuidString.prefix(8).lowercased())"
        var taskIDs: [String] = []
        for _ in 0..<2 {
            let created = try runCLI(["task", "create", "--title", title, "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any]
            taskIDs.append(try XCTUnwrap(created?["id"] as? String))
        }

        if isLiveIntegration {
            for taskID in taskIDs { try useLiveProvider(taskID: taskID) }
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
            XCTAssertEqual(processes.map(\.process.terminationStatus).sorted(), [0, 0])
            XCTAssertTrue(responses.allSatisfy { $0["ok"] as? Bool == true }, "Both live turns should start with their own branch.")
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
                XCTAssertTrue(card.waitToExist(timeout: 10), "Pending tasks should remain visible on the board before conversation start.")
            }

            // Materialize the first task's generated branch, then start the second:
            // it must get its own suffixed branch and worktree instead of a rejection.
            codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
            let winnerID = taskIDs[0]
            let loserID = taskIDs[1]
            _ = try runCLI(["conversation", "send", winnerID, "--message", "Claim the generated branch.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
            let claimed = try XCTUnwrap((try taskRecord(id: winnerID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            XCTAssertEqual(claimed["isPending"] as? Bool, false)
            let claimedCount = try runGitOutput(fixture.primary, "worktree", "list", "--porcelain").components(separatedBy: "worktree ").count - 1
            XCTAssertEqual(claimedCount, existingWorktreeCount + 1)
            _ = try runCLI(["conversation", "send", loserID, "--message", "Claim the same generated title.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
            let started = try XCTUnwrap((try taskRecord(id: loserID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            XCTAssertEqual(started["isPending"] as? Bool, false)
            XCTAssertNotEqual(started["branch"] as? String, claimed["branch"] as? String)
            XCTAssertNotEqual(started["worktreePath"] as? String, claimed["worktreePath"] as? String)
            XCTAssertEqual(try runGitOutput(fixture.primary, "worktree", "list", "--porcelain").components(separatedBy: "worktree ").count - 1, claimedCount + 1)
            return
        }
    }
    // case-contract: test_auto_branch_gets_suffix_when_name_is_taken | Two tasks with the same title and an automatic branch on one repository both start: the first gets the title slug, the second a fresh branch named like the slug plus a hyphen and four lowercase letters or digits, in a different worktree. An existing local branch named like the slug, with no task using it, is never checked out: a new automatic task gets a suffixed fresh branch started from its branch-from. The visible task conversation shows the resolved suffixed branch.
    func test_auto_branch_gets_suffix_when_name_is_taken() throws {
        launchApp(defaultParent: fixture.parent.path)
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let token = UUID().uuidString.prefix(8).lowercased()
        let title = "Suffix branch \(token)"
        let slug = "suffix-branch-\(token)"
        func startTask(_ title: String, branchFrom: String? = nil) throws -> (id: String, record: [String: Any]) {
            var command = ["task", "create", "--title", title, "--prompt", "Fixture task description.", "--repo", fixture.primary.path]
            if let branchFrom { command += ["--branch-from", "\(fixture.primary.path)=\(branchFrom)"] }
            let created = try XCTUnwrap(try runCLI(command)["result"] as? [String: Any])
            let id = try XCTUnwrap(created["id"] as? String)
            _ = try runCLI(["conversation", "send", id, "--message", "Start this task.", "--answer", "color=Blue", "--answer", "token=fixture-secret"])
            let record = try XCTUnwrap((try taskRecord(id: id)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            return (id, record)
        }
        func isSuffixed(_ branch: String, of slug: String) -> Bool {
            branch.range(of: "^\(NSRegularExpression.escapedPattern(for: slug))-[a-z0-9]{4}$", options: .regularExpression) != nil
        }

        let first = try startTask(title)
        let second = try startTask(title)
        XCTAssertEqual(first.record["branch"] as? String, slug)
        let secondBranch = try XCTUnwrap(second.record["branch"] as? String)
        XCTAssertTrue(isSuffixed(secondBranch, of: slug), "The second branch should be the slug plus a short suffix: \(secondBranch)")
        XCTAssertNotEqual(first.record["worktreePath"] as? String, second.record["worktreePath"] as? String)

        let staleSlug = "stale-branch-\(token)"
        try runGit(fixture.primary, "branch", staleSlug, "HEAD")
        let staleCommit = try runGitOutput(fixture.primary, "rev-parse", staleSlug)
        try runGit(fixture.primary, "branch", "branch-source-for-suffix", "HEAD")
        let third = try startTask("Stale branch \(token)", branchFrom: "branch-source-for-suffix")
        let thirdBranch = try XCTUnwrap(third.record["branch"] as? String)
        XCTAssertTrue(isSuffixed(thirdBranch, of: staleSlug), "An existing branch must not be reused: \(thirdBranch)")
        XCTAssertEqual(third.record["branchFrom"] as? String, "branch-source-for-suffix")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", staleSlug), staleCommit)

        let secondCard = element("task-card-\(second.id.uppercased())")
        XCTAssertTrue(secondCard.waitToExist(timeout: 10), "The second task should be on the board.")
        clickTaskCardTitle(secondCard)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 10))
        badge.click()
        let branchValue = element("conversation-repository-branch-value")
        XCTAssertTrue(branchValue.waitToExist(timeout: 5))
        XCTAssertEqual(accessibleLabelOrValue(of: branchValue), secondBranch, "The conversation should show the second task's suffixed branch.")
        attachScreenshot(named: "A task keeps its resolved branch when another task already used the slug")
    }

    // case-contract: test_cli_help_lists_commands_by_group_and_audience | The CLI's help is printed from its single command catalog, which the parser also requires: help, help <group> and <group> --help print that group's declared commands with their usage and a one-line description, and --for <audience> narrows them to one agent. The standalone chat's help lists the board commands, task create and every schedule command but no internal command (schedule tick) and no task-only command (task outcome, task progress publish, task pr autopilot, task move to Done --discard-changes); the task agent's help lists those task commands and still no internal one; the side chat's help lists only the read-only board commands its hook lets it run, the same list it is refused with, and never the option that starts a task; the plugin editor's help lists plugin render and no task or schedule command. The full help lists everything, internal commands marked. An unknown group or audience and an undeclared command or operation are refused as invalid_argument, pointing at help. Following the chat's help, a new task is created and scheduled once for tomorrow at 09:00 with schedule set, and it is in schedule list and in the Scheduled Tasks popover with that run time. The help reads only the CLI's own catalog and the schedule goes through the shared board manager, so provider selection cannot change either; no provider runs.
    func test_cli_help_lists_commands_by_group_and_audience() throws {
        launchApp(defaultParent: fixture.parent.path)
        /// The CLI's help: plain text, not a JSON response.
        func helpText(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = cliURL
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectory.path
            environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(arguments): \(text)")
            return text
        }
        func commands(_ text: String) -> [String] {
            text.components(separatedBy: "\n").filter { $0.hasPrefix("  playhouse ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func refused(_ arguments: [String]) throws -> String {
            let response = try runCLI(arguments, expectedStatus: 2)
            assertCLIError(response, code: "invalid_argument")
            let message = ((response["error"] as? [String: Any])?["message"] as? String) ?? ""
            XCTAssertTrue(message.contains("help"), "\(arguments) should point at help: \(message)")
            return message
        }

        let full = try helpText(["help"])
        XCTAssertTrue(full.contains("`playhouse` stands for this CLI: \(cliURL.path)"), full)
        XCTAssertEqual(try helpText([]), full, "Running the CLI with no arguments prints the full help.")
        XCTAssertTrue(full.contains("  playhouse schedule tick [--now <ISO8601>]"))
        XCTAssertTrue(full.contains("each minute. (internal)"), "The full help marks internal commands.")
        XCTAssertTrue(full.contains("  playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>]"))

        // One group, asked either way, lists only its own commands, each with a description.
        let schedule = try helpText(["help", "schedule"])
        XCTAssertEqual(try helpText(["schedule", "--help"]), schedule)
        XCTAssertFalse(commands(schedule).isEmpty)
        XCTAssertTrue(commands(schedule).allSatisfy { $0.hasPrefix("playhouse schedule ") }, schedule)
        XCTAssertTrue(commands(schedule).contains("playhouse schedule set <task-id> --prompt <text> --once <ISO8601> [--title <title>] [--image <path>...] [--mode default|plan] [--model <id>]"))
        XCTAssertTrue(schedule.contains("      Schedule a task to start once with this prompt"))
        XCTAssertTrue(commands(try helpText(["task", "--help"])).contains("playhouse task create --title <title> --prompt <text> [--root <path>...] [--provider <codex|claude>]"))
        XCTAssertEqual(try helpText(["task", "pr", "--help"]), try helpText(["help", "task", "pr"]))
        XCTAssertTrue(commands(try helpText(["help", "task", "pr"])).allSatisfy { $0.hasPrefix("playhouse task pr ") })

        let chat = try helpText(["help", "--for", "chat"])
        for line in ["playhouse task create --title <title> --prompt <text> [--root <path>...] [--provider <codex|claude>]",
                     "playhouse schedule list", "playhouse schedule clear|pause|resume|run-now <task-id>",
                     "playhouse workspace repos list", "playhouse plugin mode [--on|--off]"] {
            XCTAssertTrue(commands(chat).contains(line), "The chat's help should list \(line).")
        }
        XCTAssertTrue(commands(chat).contains { $0.hasPrefix("playhouse schedule set <task-id> --prompt <text> --once ") })
        for hidden in ["schedule tick", "task outcome", "task progress publish", "task pr autopilot", "--discard-changes", "(internal)", "chat page new"] {
            XCTAssertFalse(chat.contains(hidden), "The chat's help must not list \(hidden).")
        }
        XCTAssertEqual(try helpText(["schedule", "--help", "--for", "chat"]), try helpText(["help", "schedule", "--for", "chat"]))
        XCTAssertFalse(try helpText(["help", "schedule", "--for", "chat"]).contains("schedule tick"))

        let task = try helpText(["help", "--for", "task"])
        for line in ["playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>]",
                     "playhouse task move <task-id> Done --discard-changes", "playhouse task repository add <task-id> --repo <path>",
                     "playhouse task repository add-worktree <task-id> --repo <path> [--branch <name>] [--branch-from <ref>]",
                     "playhouse task pr link <task-id> (--worktree <path>|--repo <path>) --url <pr-url>"] {
            XCTAssertTrue(commands(task).contains(line), "The task agent's help should list \(line).")
        }
        XCTAssertTrue(commands(task).contains { $0.hasPrefix("playhouse task progress publish ") })
        XCTAssertTrue(commands(task).contains { $0.hasPrefix("playhouse task pr autopilot ") })
        XCTAssertFalse(task.contains("schedule tick"))
        XCTAssertFalse(task.contains("(internal)"))

        let side = Set(commands(try helpText(["help", "--for", "side-chat"])).map { line in
            String(line.components(separatedBy: " <")[0].components(separatedBy: " --")[0].components(separatedBy: " [")[0])
        })
        XCTAssertEqual(side.sorted(), [
            "playhouse help", "playhouse task create", "playhouse task get|show", "playhouse task list", "playhouse task prompt",
            "playhouse task rename", "playhouse version", "playhouse workspace repos list",
        ])

        XCTAssertFalse(try helpText(["help", "--for", "side-chat"]).contains("--submitted"), "A read-only side chat can't start a task.")
        let editor = commands(try helpText(["help", "--for", "plugin-editor"]))
        XCTAssertTrue(editor.contains { $0.hasPrefix("playhouse plugin render ") }, "\(editor)")
        XCTAssertFalse(editor.contains { $0.hasPrefix("playhouse task ") || $0.hasPrefix("playhouse schedule ") }, "\(editor)")

        XCTAssertTrue(try refused(["help", "nosuch"]).contains("Groups: help, status"))
        XCTAssertTrue(try refused(["help", "--for", "nobody"]).contains("chat, side-chat, task, plugin-editor"))
        XCTAssertTrue(try refused(["task", "bogus"]).contains("playhouse help task"))
        XCTAssertTrue(try refused(["frobnicate"]).contains("playhouse help"))

        // An agent that follows the chat's help can schedule a task for tomorrow at 09:00.
        let once = try XCTUnwrap(commands(chat).first { $0.hasPrefix("playhouse schedule set <task-id> --prompt <text> --once ") })
        XCTAssertTrue(once.contains("--once <ISO8601>"))
        let taskID = try XCTUnwrap((try runCLI([
            "task", "create", "--title", "Write the release notes", "--prompt", "Write the release notes for the next version.",
        ])["result"] as? [String: Any])?["id"] as? String)
        let calendar = Calendar.current
        let tomorrow = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: Date()))))
        _ = try runCLI(["schedule", "set", taskID, "--prompt", "Write the release notes.", "--once", scheduleISO(tomorrow)])
        let listed = try XCTUnwrap((try runCLI(["schedule", "list"])["result"] as? [String: Any])?["tasks"] as? [[String: Any]])
        XCTAssertEqual(listed.compactMap { $0["id"] as? String }, [taskID])
        XCTAssertEqual(scheduleDate((listed.first?["schedule"] as? [String: Any])?["scheduledAt"] as? String), tomorrow)

        openScheduledTasksPopover()
        let surface = element("plugin-surface-scheduled-tasks")
        XCTAssertTrue(element("scheduled-task-row-\(taskID)").waitToExist(timeout: 10), "The scheduled task should be in the Scheduled Tasks popover.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("scheduled-task-title-\(taskID)")), "Write the release notes")
        XCTAssertEqual(accessibleLabelOrValue(of: element("scheduled-task-summary-\(taskID)")), "Tomorrow 09:00")
        attachScreenshot(named: "A task scheduled through the chat's help is in Scheduled Tasks")
        attachElementScreenshot(surface, named: "Scheduled Tasks popover with the task scheduled for tomorrow at 09:00")
    }
}

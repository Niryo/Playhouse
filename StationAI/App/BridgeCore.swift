import Foundation
import SwiftData
import Darwin
import SQLite3

@MainActor
struct CodexTaskTitleGenerator {
    let client: CodexAppServerClient

    func generateTitle(from prompt: String, workspace: CodexWorkspaceContext, taskID: UUID) async -> String? {
        var phase = "thread-start"
        var threadID = ""
        do {
            threadID = try await client.startThread(workspace: workspace, modelID: CodexAppServerClient.modelID)
            StationAIDiagnostics.record("task.title_generation.started", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "modelID": CodexAppServerClient.modelID
            ])
            var generated: String?
            phase = "title-turn"
            try await client.sendMessage(
                "Write a concise task title of at most 8 words for this request. Return only the title:\n\n\(prompt)",
                mode: .plan,
                modelID: CodexAppServerClient.modelID,
                threadID: threadID,
                workspace: workspace,
                onDelta: { _ in },
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                onActionRequest: {}, onUserInput: { _ in }
            )
            guard let title = generated?.components(separatedBy: .newlines).first,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                StationAIDiagnostics.record("task.title_generation.failed", fields: [
                    "taskID": taskID.uuidString,
                    "threadID": threadID,
                    "phase": phase,
                    "reason": "empty_response"
                ])
                return nil
            }
            StationAIDiagnostics.record("task.title_generation.succeeded", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "phase": phase,
                "titleWordCount": String(title.split(whereSeparator: \.isWhitespace).count)
            ])
            return title
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [prompt])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["phase"] = phase
            StationAIDiagnostics.record("task.title_generation.failed", fields: fields)
            return nil
        }
    }
}

enum StationAITaskTitleDiagnostics {
    static func state(of title: String) -> String {
        switch title {
        case "Untitled task": "untitled"
        case "Generating title…": "generating"
        default: "custom"
        }
    }
}

@MainActor
enum StationAIStore {
    private static var lifecycleGateHeld = false
    private static var lifecycleGateWaiters: [CheckedContinuation<Void, Never>] = []

    static func storeURL(dataDirectory: String? = nil) throws -> URL {
        if let dataDirectory {
            if !StationAIAppIdentity.isTestBundle {
                let requested = URL(fileURLWithPath: dataDirectory, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL
                let expected = try StationAIAppIdentity.defaultDataDirectory()
                    .resolvingSymlinksInPath().standardizedFileURL
                guard requested == expected else {
                    throw StoreSchemaRepairError("This StationAI worktree app cannot open another app’s task store.")
                }
            }
            return URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("StationAI-v2.store")
        }
        let supportDirectory = try StationAIAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent("StationAI-v2.store")
    }

    static func makeContainer(dataDirectory: String? = nil) throws -> ModelContainer {
        try validateTestDataDirectory(dataDirectory)
        let schema = Schema([BoardTask.self])
        let storeURL: URL
        do {
            storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        } catch {
            // A rejected linked-app override must not send diagnostics to that foreign store directory.
            let profileDirectory = StationAIAppIdentity.worktreeKey != nil
                ? try? StationAIAppIdentity.defaultDataDirectory().path : nil
            StationAIDiagnostics.useDataDirectory(profileDirectory)
            StationAIDiagnostics.recordAndFlush(
                "persistence.store.path.failed",
                fields: StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)
                    .merging(["phase": "resolve-store-path"]) { _, new in new }
            )
            throw error
        }
        StationAIDiagnostics.useDataDirectory(dataDirectory)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacyStoreURL = storeURL.deletingLastPathComponent().appendingPathComponent("StationAI.store")
            if FileManager.default.fileExists(atPath: legacyStoreURL.path) || (try? storeNeedsPendingPromptColumn(storeURL)) == true {
                StationAIDiagnostics.recordAndFlush("persistence.store.schema_migration.waiting_for_schema_lock", fields: [
                    "storePath": storeURL.path
                ])
            }
            return try withSchemaRepairLock(at: storeURL) {
                try importLegacyStoreIfNeeded(at: storeURL)
                // A legacy store can have both an old model hash and a missing column.
                // Opening SwiftData first can fail before the table repair is reached.
                let configuration = ModelConfiguration(
                    "StationAI",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                if try storeNeedsPendingPromptColumn(storeURL) {
                    // Hold the write lock through SwiftData's model metadata update.
                    let waitStartedAt = Date()
                    StationAIDiagnostics.recordAndFlush("persistence.store.schema_migration.waiting_for_write_lock", fields: [
                        "storePath": storeURL.path
                    ])
                    return try withStoreWriteLock(at: storeURL) {
                        StationAIDiagnostics.recordAndFlush("persistence.store.schema_migration.write_lock_acquired", fields: [
                            "storePath": storeURL.path,
                            "waitMilliseconds": String(Int(Date().timeIntervalSince(waitStartedAt) * 1_000))
                        ])
                        let backupURL = try storeNeedsPendingPromptColumn(storeURL)
                            ? repairPendingPromptColumn(at: storeURL) : nil
                        let container = try ModelContainer(for: schema, configurations: [configuration])
                        guard try !storeNeedsPendingPromptColumn(storeURL) else {
                            throw StoreSchemaRepairError("The task store still lacks the pending prompt column after migration.")
                        }
                        if let backupURL {
                            StationAIDiagnostics.record("persistence.store.schema_repaired", fields: [
                                "storePath": storeURL.path,
                                "backupPath": backupURL.path,
                                "column": "ZPENDINGSUBMITTEDPROMPT"
                            ])
                        }
                        return container
                    }
                }
                let container = try ModelContainer(for: schema, configurations: [configuration])
                guard try !storeNeedsPendingPromptColumn(storeURL) else {
                    throw StoreSchemaRepairError("The task store lacks the pending prompt column after opening.")
                }
                return container
            }
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)
            fields.merge(StationAIDiagnostics.storeContextFields(for: storeURL)) { _, new in new }
            fields.merge(Self.schemaProbeFields(at: storeURL)) { _, new in new }
            fields["phase"] = "model-container-open"
            StationAIDiagnostics.recordAndFlush("persistence.store.open.failed", fields: fields)
            throw error
        }
    }

    private static func validateTestDataDirectory(_ dataDirectory: String?) throws {
        #if DEBUG
        guard StationAIAppIdentity.isTestBundle else { return }
        guard let dataDirectory, !dataDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreSchemaRepairError("A StationAI test bundle requires an isolated data directory.")
        }
        let path = URL(fileURLWithPath: dataDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = [FileManager.default.temporaryDirectory.path, "/tmp"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path }
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw StoreSchemaRepairError("A StationAI test bundle requires an isolated temporary data directory.")
        }
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: dataDirectory, isDirectory: true)
                .appendingPathComponent("StationAI-v2.store" + suffix)
            var metadata = stat()
            if Darwin.lstat(candidate.path, &metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw StoreSchemaRepairError("A StationAI test bundle cannot open a linked task store.")
            }
        }
        #endif
    }

    /// Probe the task schema only after a persistence failure. SwiftData's NSError often
    /// contains SQLite code 1 but omits the SQL message that explains a missing column.
    static func schemaProbeFields(at storeURL: URL?) -> [String: String] {
        guard let storeURL else { return ["schemaProbeResult": "store-path-unavailable"] }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            storeURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let database { sqlite3_close(database) }
            return [
                "schemaProbeResult": "open-failed",
                "schemaProbeSQLiteCode": String(openStatus),
                "schemaProbeSQLiteMessage": String(message.prefix(2_048))
            ]
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        // Keep this projection aligned with the persisted properties of BoardTask. A
        // zero-row query validates table and column names without reading task data.
        let query = """
            SELECT t0.ZID, t0.ZTITLE, t0.ZSTATUSRAWVALUE, t0.ZSTATUSMESSAGE,
                   t0.ZPROGRESSTYPERAWVALUE, t0.ZPROGRESSLABEL, t0.ZPROGRESSDETAIL,
                   t0.ZCREATEDAT, t0.ZCODEXTHREADID, t0.ZSAVEDPROMPT,
                   t0.ZPENDINGSUBMITTEDPROMPT, t0.ZWORKSPACEROOTPATHSDATA,
                   t0.ZREPOSITORYWORKTREESDATA, t0.ZCONTEXTFOLDERPATHSDATA,
                   t0.ZDRAFTIMAGEDATAURLSDATA
            FROM ZBOARDTASK t0 LIMIT 0
            """
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepareStatus == SQLITE_OK, let statement else {
            return [
                "schemaProbeResult": "prepare-failed",
                "schemaProbeSQLiteCode": String(sqlite3_extended_errcode(database)),
                "schemaProbeSQLiteMessage": String(String(cString: sqlite3_errmsg(database)).prefix(2_048))
            ]
        }
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_DONE else {
            return [
                "schemaProbeResult": "step-failed",
                "schemaProbeSQLiteCode": String(sqlite3_extended_errcode(database)),
                "schemaProbeSQLiteMessage": String(String(cString: sqlite3_errmsg(database)).prefix(2_048))
            ]
        }
        return ["schemaProbeResult": "ok"]
    }

    private static func withSchemaRepairLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("store-schema-repair.lock")
        return try withStoreFileLock(at: lockURL, body)
    }

    private static func withStoreWriteLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("store-write.lock")
        return try withStoreFileLock(at: lockURL, body)
    }

    private static func withStoreFileLock<T>(at lockURL: URL, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try body()
    }

    private static func withSQLite<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let database { sqlite3_close(database) }
            throw StoreSchemaRepairError(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        return try body(database)
    }

    // A new filename keeps binaries predating the compatibility contract away from
    // live data. Import a consistent SQLite snapshot once; never reopen the legacy
    // path with SwiftData or overwrite an already imported store.
    private static func importLegacyStoreIfNeeded(at destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let source = destination.deletingLastPathComponent().appendingPathComponent("StationAI.store")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        var metadata = stat()
        guard Darwin.lstat(source.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw StoreSchemaRepairError("The legacy task store must be a regular file.")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".store-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var input: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let input else {
            if let input { sqlite3_close(input) }
            throw StoreSchemaRepairError("Couldn't read the legacy task store for import.")
        }
        defer { sqlite3_close(input) }
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        _ = Darwin.close(descriptor)
        try withSQLite(at: temporary) { output in
            guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
                throw StoreSchemaRepairError("Couldn't start the legacy task store snapshot.")
            }
            var status = sqlite3_backup_step(backup, -1)
            var retries = 0
            while (status == SQLITE_BUSY || status == SQLITE_LOCKED) && retries < 100 {
                sqlite3_sleep(50)
                status = sqlite3_backup_step(backup, -1)
                retries += 1
            }
            let finished = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE, finished == SQLITE_OK else {
                throw StoreSchemaRepairError("Couldn't complete the legacy task store snapshot.")
            }
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(output, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK else {
                throw StoreSchemaRepairError("Couldn't check the imported task store.")
            }
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, let result = sqlite3_column_text(check, 0),
                  String(cString: result) == "ok" else {
                throw StoreSchemaRepairError("The legacy task store failed its integrity check.")
            }
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        StationAIDiagnostics.recordAndFlush("persistence.store.legacy_imported", fields: [
            "legacyPath": source.path, "storePath": destination.path
        ])
    }

    private static func storeNeedsPendingPromptColumn(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try withSQLite(at: url) { database in
            let columns = try taskStoreColumns(in: database)
            guard columns.contains("ZID"), columns.contains("ZTITLE"), columns.contains("ZSAVEDPROMPT") else {
                return false
            }
            let requiredColumns = [
                "ZPENDINGSUBMITTEDPROMPT",
                "ZINPROGRESSSTARTEDAT",
                "ZTOTALINPROGRESSSECONDS",
                "ZDRAFTIMAGEDATAURLSDATA"
            ]
            return requiredColumns.contains { !columns.contains($0) }
        }
    }

    private static func taskStoreColumns(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZBOARDTASK)", -1, &statement, nil) == SQLITE_OK else {
            throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
        }
        return columns
    }

    private static func repairPendingPromptColumn(at url: URL) throws -> URL {
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(
            "StationAI.store.before-pending-prompt-\(UUID().uuidString).backup"
        )
        try withSQLite(at: url) { database in
            let backupDescriptor = Darwin.open(backupURL.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard backupDescriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            _ = Darwin.close(backupDescriptor)
            var backupDatabase: OpaquePointer?
            guard sqlite3_open_v2(backupURL.path, &backupDatabase, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let backupDatabase else {
                if let backupDatabase { sqlite3_close(backupDatabase) }
                throw StoreSchemaRepairError("Couldn't create a task-store backup before schema repair.")
            }
            defer { sqlite3_close(backupDatabase) }
            sqlite3_busy_timeout(backupDatabase, 5_000)
            guard let backup = sqlite3_backup_init(backupDatabase, "main", database, "main") else {
                throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(backupDatabase)))
            }
            var backupStatus = sqlite3_backup_step(backup, -1)
            var backupRetries = 0
            while (backupStatus == SQLITE_BUSY || backupStatus == SQLITE_LOCKED) && backupRetries < 100 {
                sqlite3_sleep(50)
                backupStatus = sqlite3_backup_step(backup, -1)
                backupRetries += 1
            }
            let finishStatus = sqlite3_backup_finish(backup)
            guard backupStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
                throw StoreSchemaRepairError("Couldn't finish the task-store backup before schema repair.")
            }
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
            }
            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZBOARDTASK)", -1, &statement, nil) == SQLITE_OK else {
                    throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
                }
                defer { sqlite3_finalize(statement) }
                var columns = Set<String>()
                var stepStatus = sqlite3_step(statement)
                while stepStatus == SQLITE_ROW {
                    if let name = sqlite3_column_text(statement, 1) {
                        columns.insert(String(cString: name))
                    }
                    stepStatus = sqlite3_step(statement)
                }
                guard stepStatus == SQLITE_DONE else {
                    throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
                }
                sqlite3_finalize(statement)
                statement = nil
                let requiredColumns: [(String, String)] = [
                    ("ZPENDINGSUBMITTEDPROMPT", "VARCHAR"),
                    ("ZINPROGRESSSTARTEDAT", "TIMESTAMP"),
                    ("ZTOTALINPROGRESSSECONDS", "FLOAT"),
                    ("ZDRAFTIMAGEDATAURLSDATA", "BLOB")
                ]
                for (column, declaration) in requiredColumns where !columns.contains(column) {
                    let sql = "ALTER TABLE ZBOARDTASK ADD COLUMN \(column) \(declaration)"
                    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                        throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
                    }
                }
                guard sqlite3_exec(
                    database,
                    "UPDATE ZBOARDTASK SET ZTOTALINPROGRESSSECONDS = 0 WHERE ZTOTALINPROGRESSSECONDS IS NULL",
                    nil,
                    nil,
                    nil
                ) == SQLITE_OK else {
                    throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
                }
                guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw StoreSchemaRepairError(String(cString: sqlite3_errmsg(database)))
                }
            } catch {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
        return backupURL
    }

    @MainActor
    static func prepareLifecycle(container: ModelContainer, dataDirectory: String? = nil) async throws {
        await Self.acquireLifecycleGate()
        defer { Self.releaseLifecycleGate() }
        let storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        let directory = storeURL.deletingLastPathComponent()
        let marker = directory.appendingPathComponent("task-lifecycle-v2-reset")
        let lockURL = directory.appendingPathComponent("task-lifecycle-v2-reset.lock")
        let lockDescriptor = try await Self.acquireLifecycleLock(at: lockURL)
        defer { _ = Darwin.close(lockDescriptor) }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let context = ModelContext(container)
        let dirtyWorktrees = try await BoardTaskManager(modelContext: context).resetAllTasksForLifecycle()
        if !dirtyWorktrees.isEmpty {
            let notice = directory.appendingPathComponent("task-lifecycle-v2-notice.json")
            try JSONEncoder().encode(dirtyWorktrees).write(to: notice, options: .atomic)
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
    }

    private static func acquireLifecycleGate() async {
        guard lifecycleGateHeld else {
            lifecycleGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleGateWaiters.append(continuation)
        }
    }

    private static func releaseLifecycleGate() {
        guard !lifecycleGateWaiters.isEmpty else {
            lifecycleGateHeld = false
            return
        }
        lifecycleGateWaiters.removeFirst().resume()
    }

    private static func acquireLifecycleLock(at url: URL) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw StoreLifecycleLockError(message: "Couldn't open the task-store lifecycle lock (errno \(errno)).")
            }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
                if errno == EACCES || errno == EAGAIN {
                    usleep(50_000)
                    continue
                }
                let code = errno
                _ = Darwin.close(descriptor)
                throw StoreLifecycleLockError(message: "Couldn't acquire the task-store lifecycle lock (errno \(code)).")
            }
            return descriptor
        }.value
    }

    static func takeLifecycleResetNotice(dataDirectory: String? = nil) -> [String] {
        guard let directory = try? Self.storeURL(dataDirectory: dataDirectory).deletingLastPathComponent() else { return [] }
        let notice = directory.appendingPathComponent("task-lifecycle-v2-notice.json")
        guard let data = try? Data(contentsOf: notice),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: notice)
        return paths
    }
}

private struct StoreLifecycleLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct StoreSchemaRepairError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct BridgeFileLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private enum RepositoryAllocationLock {
    static func fileName(for repositoryPath: String) -> String {
        let canonicalPath = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonicalPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(format: "%016llx.lock", hash)
    }
}

@MainActor
private enum TaskOperationLockGate {
    private static var heldKeys: Set<String> = []
    private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func acquire(_ key: String) async {
        guard !heldKeys.contains(key) else {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
            return
        }
        heldKeys.insert(key)
    }

    static func isHeld(_ key: String) -> Bool {
        heldKeys.contains(key)
    }

    static func release(_ key: String) {
        guard var pending = waiters[key], !pending.isEmpty else {
            heldKeys.remove(key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        next.resume()
    }
}

struct BoardTaskRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let status: String
    let statusMessage: String?
    let progressType: String?
    let progressLabel: String?
    let progressDetail: String?
    let createdAt: Date
    let codexThreadID: String?
    let savedPrompt: String?
    let pendingSubmittedPrompt: String?
    let workspaceRoots: [String]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    let contextFolders: [String]
    let draftImageDataURLs: [String]?

    init(task: BoardTask, includeDraftImages: Bool = true) {
        id = task.id
        title = task.title
        status = task.status.rawValue
        statusMessage = task.statusMessage
        progressType = task.progressTypeRawValue
        progressLabel = task.progressLabel
        progressDetail = task.progressDetail
        createdAt = task.createdAt
        codexThreadID = task.codexThreadID
        savedPrompt = task.savedPrompt
        pendingSubmittedPrompt = task.pendingSubmittedPrompt
        workspaceRoots = task.workspaceRootPaths
        repositoryWorktrees = task.repositoryWorktrees
        contextFolders = task.contextFolderPaths
        draftImageDataURLs = includeDraftImages ? task.draftImageDataURLs : nil
    }
}

struct QueuedConversationMessage: Codable, Equatable, Identifiable {
    enum State: String, Codable { case queued, dispatching, needsAction }
    let id: UUID
    let taskID: UUID
    let threadID: String
    let text: String
    var imageDataURLs: [String]? = []
    var state: State
    var enqueuedProcessID: Int32? = nil
    var dispatchingProcessID: Int32? = nil
}

enum GitHubPullRequestManager {
    struct PullRequest: Decodable, Sendable {
        let number: Int
        let url: String
        let baseRefName: String?
    }

    private struct PullRequestState: Decodable {
        let mergedAt: String?
    }

    private struct PullRequestReviewResponse: Decodable {
        let mergedAt: String?
        let mergeable: String?
        let headRefOid: String?
    }

    static func reviewState(_ record: RepositoryWorktreeRecord, executable: String) throws -> PullRequestReviewState {
        guard let number = record.pullRequestNumber else {
            throw BridgeCommandError(code: "invalid_transition", message: "This repository has no linked pull request.")
        }
        let result = try run(executable, ["pr", "view", String(number), "--json", "mergedAt,mergeable,headRefOid"], directory: record.worktreePath)
        let response = try JSONDecoder().decode(PullRequestReviewResponse.self, from: Data(result.utf8))
        let localHead: String?
        if response.headRefOid != nil {
            let git = try StationAIProcessRunner.run(executable: "/usr/bin/git", arguments: ["rev-parse", "HEAD"], directory: record.worktreePath)
            guard git.status == 0 else {
                throw BridgeCommandError(code: "operation_failed", message: "Couldn't inspect the local head for pull request #\(number).")
            }
            localHead = String(data: git.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            localHead = nil
        }
        return PullRequestReviewState(
            repositoryPath: record.repositoryPath, number: number,
            merged: response.mergedAt != nil, mergeable: response.mergeable ?? "UNKNOWN",
            headRefOid: response.headRefOid, localHeadOid: localHead
        )
    }

    static func resolveExecutable() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("gh").path
        } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI (gh) isn't available. Install GitHub CLI and try again.")
        }
        return path
    }

    static func findOpen(_ record: RepositoryWorktreeRecord, executable: String) throws -> PullRequest? {
        let result = try run(executable, ["pr", "list", "--head", record.branch, "--state", "open", "--json", "number,url,baseRefName", "--limit", "1"], directory: record.worktreePath)
        guard let pullRequest = try JSONDecoder().decode([PullRequest].self, from: Data(result.utf8)).first else {
            return nil
        }
        if let mergeTarget = configuredMergeTarget(for: record) {
            guard let baseRefName = pullRequest.baseRefName else {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "GitHub couldn't confirm the base branch of the existing pull request for \(record.branch). Its configured merge target is \(mergeTarget)."
                )
            }
            guard baseRefName == mergeTarget else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "An open pull request for \(record.branch) targets \(baseRefName), but this repository is configured to merge into \(mergeTarget). The existing pull request was left unchanged."
                )
            }
        }
        return pullRequest
    }

    static func create(_ record: RepositoryWorktreeRecord, title: String, body: String, executable: String) throws -> PullRequest {
        var arguments = ["pr", "create", "--title", title, "--body", body, "--head", record.branch]
        if let mergeTarget = configuredMergeTarget(for: record) {
            arguments += ["--base", mergeTarget]
        }
        let result = try run(executable, arguments, directory: record.worktreePath)
        guard let url = result.split(whereSeparator: \.isNewline).last.map(String.init),
              URL(string: url)?.host != nil,
              let number = URL(string: url)?.pathComponents.last.flatMap(Int.init) else {
            throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI created a pull request but did not return its number and URL.")
        }
        return PullRequest(number: number, url: url, baseRefName: nil)
    }

    private static func configuredMergeTarget(for record: RepositoryWorktreeRecord) -> String? {
        guard let mergeTarget = record.mergeTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mergeTarget.isEmpty else {
            return nil
        }
        return mergeTarget
    }

    static func isMerged(_ record: RepositoryWorktreeRecord, executable: String) throws -> Bool {
        guard let number = record.pullRequestNumber else { return true }
        let result = try run(executable, ["pr", "view", String(number), "--json", "mergedAt"], directory: record.worktreePath)
        return try JSONDecoder().decode(PullRequestState.self, from: Data(result.utf8)).mergedAt != nil
    }

    private static func run(_ executable: String, _ arguments: [String], directory: String) throws -> String {
        let result: StationAIProcessResult
        do {
            result = try StationAIProcessRunner.run(
                executable: executable,
                arguments: arguments,
                directory: directory
            )
        } catch {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't start GitHub CLI: \(error.localizedDescription)")
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let guidance = detail.localizedCaseInsensitiveContains("auth") || detail.localizedCaseInsensitiveContains("login")
                ? "GitHub CLI isn't authorized. Run `gh auth login` in Terminal, then try again. "
                : "GitHub CLI couldn't complete the request. "
            throw BridgeCommandError(code: "operation_failed", message: guidance + (detail.isEmpty ? "Exit status \(result.status)." : detail))
        }
        return text
    }
}

struct PullRequestReviewState: Codable, Sendable {
    let repositoryPath: String
    let number: Int
    let merged: Bool
    let mergeable: String
    let headRefOid: String?
    let localHeadOid: String?
    let hasConflicts: Bool
    let isConfirmedResolved: Bool

    var requiresConflictResolution: Bool {
        hasConflicts || (!merged && mergeable == "MERGEABLE" && headRefOid != nil && headRefOid != localHeadOid)
    }

    init(repositoryPath: String, number: Int, merged: Bool, mergeable: String, headRefOid: String?, localHeadOid: String?) {
        self.repositoryPath = repositoryPath
        self.number = number
        self.merged = merged
        self.mergeable = mergeable
        self.headRefOid = headRefOid
        self.localHeadOid = localHeadOid
        hasConflicts = !merged && mergeable == "CONFLICTING"
        isConfirmedResolved = merged || (mergeable == "MERGEABLE" && headRefOid != nil && headRefOid == localHeadOid)
    }
}

enum PullRequestResolutionCheck: String, Codable, Sendable {
    case resolved
    case stillConflicted
    case inconclusive
}

struct StationAIPullRequestService {

    func resolveExecutable() throws -> String {
        try GitHubPullRequestManager.resolveExecutable()
    }

    func findOpen(_ record: RepositoryWorktreeRecord, executable: String) async throws -> GitHubPullRequestManager.PullRequest? {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.findOpen(record, executable: executable)
        }
    }

    func create(
        _ record: RepositoryWorktreeRecord,
        title: String,
        body: String,
        executable: String
    ) async throws -> GitHubPullRequestManager.PullRequest {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.create(record, title: title, body: body, executable: executable)
        }
    }

    func isMerged(_ record: RepositoryWorktreeRecord, executable: String) async throws -> Bool {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.isMerged(record, executable: executable)
        }
    }

    func reviewState(_ record: RepositoryWorktreeRecord, executable: String) async throws -> PullRequestReviewState {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.reviewState(record, executable: executable)
        }
    }
}

enum StationAIManagerError: LocalizedError {
    case invalidTitle
    case taskNotFound(UUID)
    case invalidStatus(String)
    case noWorkspaceRoots
    case unavailableWorkspaceRoot(String)
    case invalidParentFolder(String)
    case invalidMessage
    case repositoryAssigned(String)
    case invalidTransition(String)
    case unmergedPullRequests([Int])

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Task title can't be empty."
        case .taskNotFound(let id):
            "No task exists with ID \(id)."
        case .invalidStatus(let status):
            "Unknown task status '\(status)'. Valid statuses: \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))."
        case .noWorkspaceRoots:
            "Choose at least one working folder."
        case .unavailableWorkspaceRoot(let path):
            "The working folder is unavailable: \(path)"
        case .invalidParentFolder(let path):
            "The parent folder isn't an available directory: \(path)"
        case .invalidMessage:
            "Message can't be empty."
        case .repositoryAssigned(let path):
            "This branch worktree is already assigned to another active task: \(path). Choose another branch or finish that task first."
        case .invalidTransition(let message):
            message
        case .unmergedPullRequests(let numbers):
            "Pull request(s) \(numbers.map { "#\($0)" }.joined(separator: ", ")) haven't been merged. Confirm that you want to mark this task Done."
        }
    }
}

@MainActor
final class BoardTaskManager {
    private let modelContext: ModelContext
    private let worktreeRoot: URL
    private let taskOperationLockDirectory: URL?

    func queuedConversationMessages(taskID: UUID) throws -> [QueuedConversationMessage] {
        try mutateQueuedMessages(taskID: taskID) { items in
            for index in items.indices where items[index].state == .dispatching {
                let processID = items[index].dispatchingProcessID
                guard let processID, Darwin.kill(processID, 0) == 0 || errno == EPERM else {
                    items[index].state = .needsAction
                    items[index].dispatchingProcessID = nil
                    items[index].enqueuedProcessID = nil
                    continue
                }
            }
        }
        return try readQueuedMessages()[taskID.uuidString] ?? []
    }

    func enqueueConversationMessage(taskID: UUID, text: String, imageDataURLs: [String] = []) throws -> QueuedConversationMessage {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        let task = try taskModel(taskID)
        guard let threadID = task.codexThreadID else {
            throw BridgeCommandError(code: "invalid_transition", message: "A follow-up can only be queued after this conversation has a Codex thread.")
        }
        let item = QueuedConversationMessage(
            id: UUID(), taskID: taskID, threadID: threadID, text: normalized, imageDataURLs: imageDataURLs, state: .queued,
            enqueuedProcessID: nil
        )
        try mutateQueuedMessages(taskID: taskID) { $0.append(item) }
        return item
    }

    func conversationSteerMailboxDirectory() throws -> URL {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for steering requests.")
        }
        return storeURL.deletingLastPathComponent().appendingPathComponent("conversation-steer-mailbox", isDirectory: true)
    }

    func claimNextQueuedMessage(taskID: UUID, threadID: String, messageID: UUID? = nil) throws -> QueuedConversationMessage? {
        var claimed: QueuedConversationMessage?
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: {
                $0.state == .queued && $0.threadID == threadID && (messageID == nil || $0.id == messageID)
            }) else { return }
            items[index].state = .dispatching
            items[index].dispatchingProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
            claimed = items[index]
        }
        return claimed
    }

    func finishQueuedMessage(_ message: QueuedConversationMessage, succeeded: Bool) throws {
        try mutateQueuedMessages(taskID: message.taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == message.id && $0.state == .dispatching }) else { return }
            if succeeded { items.remove(at: index) }
            else { items[index].state = .needsAction; items[index].dispatchingProcessID = nil }
        }
    }

    func retryQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .needsAction }) else {
                throw BridgeCommandError(code: "invalid_transition", message: "That queued message is not waiting for an explicit retry.")
            }
            items[index].state = .queued
            items[index].enqueuedProcessID = nil
            items[index].dispatchingProcessID = nil
        }
    }

    func removeQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID }),
                  items[index].state != .dispatching else {
                throw BridgeCommandError(code: "invalid_transition", message: "That follow-up can no longer be removed.")
            }
            items.remove(at: index)
        }
    }

    func reserveQueuedMessageForSteering(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .queued }) else {
                throw BridgeCommandError(code: "invalid_transition", message: "That follow-up is no longer available to steer.")
            }
            items[index].state = .dispatching
            items[index].dispatchingProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
        }
    }

    func finishQueuedMessageSteering(taskID: UUID, messageID: UUID, accepted: Bool) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .dispatching }) else { return }
            if accepted { items.remove(at: index) }
            else {
                items[index].state = .needsAction
                items[index].dispatchingProcessID = nil
            }
        }
    }

    func requeueMissedSteer(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .dispatching }) else { return }
            items[index].state = .queued
            items[index].dispatchingProcessID = nil
        }
    }

    func retainQueuedMessagesForUserAction(taskID: UUID, threadID: String) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            for index in items.indices where items[index].threadID == threadID && items[index].state == .queued {
                items[index].state = .needsAction
            }
        }
    }

    private func readQueuedMessages() throws -> [String: [QueuedConversationMessage]] {
        let url = try queuedMessagesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [QueuedConversationMessage]].self, from: Data(contentsOf: url))
    }

    private func mutateQueuedMessages(taskID: UUID, _ mutation: (inout [QueuedConversationMessage]) throws -> Void) throws {
        let url = try queuedMessagesURL()
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { lock.l_type = Int16(F_UNLCK); _ = Darwin.fcntl(descriptor, F_SETLK, &lock) }
        var all: [String: [QueuedConversationMessage]] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            all = try JSONDecoder().decode([String: [QueuedConversationMessage]].self, from: Data(contentsOf: url))
        }
        var items = all[taskID.uuidString] ?? []
        try mutation(&items)
        all[taskID.uuidString] = items
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func queuedMessagesURL() throws -> URL {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for queued messages.")
        }
        return storeURL.deletingLastPathComponent().appendingPathComponent("queued-conversation-messages.json")
    }
    private let repositoryAllocationLockDirectory: URL?
    private let conversationTurnLockDirectory: URL?
    private let worktreeService = StationAIWorktreeService()
    private let pullRequestService = StationAIPullRequestService()

    init(modelContext: ModelContext, worktreeRoot: URL = StationAIWorktreeManager.defaultRoot()) {
        self.modelContext = modelContext
        self.worktreeRoot = worktreeRoot
        self.taskOperationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("task-operation-locks", isDirectory: true)
        self.repositoryAllocationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("repository-allocation-locks", isDirectory: true)
        self.conversationTurnLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("conversation-turn-locks", isDirectory: true)
    }

    private func withTaskOperationLock<T>(
        _ id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard let taskOperationLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for an operation lock.")
        }
        let lockURL = taskOperationLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "task-operation") {
            try await operation()
        }
    }

    private static func isStoreOpenFailure(_ error: Error) -> Bool {
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            if current.domain == NSCocoaErrorDomain, current.code == 256 {
                return true
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Reserves a task's whole conversation send across app/XPC processes.
    /// Workspace and repository changes, plus task deletion, use this same
    /// reservation so they cannot change a worktree while a turn is using it.
    /// This lock deliberately uses a separate file namespace from the short
    /// task-operation locks: streamed-turn callbacks must still acquire those
    /// locks to save lifecycle, progress, and thread state while this reservation
    /// remains held. Never hold a task-operation lock across the Codex turn.
    func withConversationTurnReservation<T>(
        _ id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        let lockURL = conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-turn") {
            try await operation()
        }
    }

    func hasConversationTurnReservation(_ id: UUID) throws -> Bool {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        let lockURL = conversationTurnLockDirectory
            .appendingPathComponent("\(id.uuidString).lock")
            .standardizedFileURL
        let key = lockURL.path
        guard !TaskOperationLockGate.isHeld(key) else { return true }

        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw BridgeFileLockError(message: "Couldn't inspect the conversation-turn reservation (errno \(errno)).")
        }
        defer { _ = Darwin.close(descriptor) }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_GETLK, &lock) == 0 else {
            throw BridgeFileLockError(message: "Couldn't inspect the conversation-turn reservation (errno \(errno)).")
        }
        return lock.l_type != Int16(F_UNLCK)
    }

    private func conversationTurnOutcomeURL(_ id: UUID) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation outcome.")
        }
        return conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).outcome")
    }

    private func conversationTurnActiveURL(_ id: UUID) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the active conversation turn.")
        }
        return conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).active")
    }

    func prepareConversationTurnOutcome(_ id: UUID) throws {
        for marker in [try conversationTurnOutcomeURL(id), try conversationTurnActiveURL(id)]
        where FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    func activateConversationTurnOutcome(_ id: UUID) throws {
        guard try hasConversationTurnReservation(id) else {
            throw BridgeCommandError(code: "invalid_transition", message: "A turn outcome requires an active conversation turn.")
        }
        let marker = try conversationTurnActiveURL(id)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
    }

    func clearConversationTurnOutcome(_ id: UUID) {
        try? FileManager.default.removeItem(at: try conversationTurnOutcomeURL(id))
        try? FileManager.default.removeItem(at: try conversationTurnActiveURL(id))
    }

    func finishConversationTurnOutcome(_ id: UUID) async throws -> String? {
        let outcomeURL = try conversationTurnOutcomeURL(id)
        let activeURL = try conversationTurnActiveURL(id)
        let lockURL = outcomeURL.appendingPathExtension("lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-outcome") {
            try? FileManager.default.removeItem(at: activeURL)
            defer { try? FileManager.default.removeItem(at: outcomeURL) }
            guard let data = try? Data(contentsOf: outcomeURL) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func withRepositoryAllocationLocks<T>(
        _ repositoryPaths: [String],
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard !repositoryPaths.isEmpty else { return try await operation() }
        guard let repositoryAllocationLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for repository allocation locks.")
        }
        let lockURLs = Set(repositoryPaths.map { repositoryPath in
            repositoryAllocationLockDirectory.appendingPathComponent(
                RepositoryAllocationLock.fileName(for: repositoryPath)
            )
        }).sorted { $0.path < $1.path }
        return try await withExclusiveFileLocks(at: lockURLs, purpose: "repository-allocation") {
            try await operation()
        }
    }

    private func withExclusiveFileLocks<T>(
        at lockURLs: [URL],
        purpose: String,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        let orderedURLs = Array(Set(lockURLs.map { $0.standardizedFileURL }))
            .sorted { $0.path < $1.path }
        var acquiredKeys: [String] = []
        var descriptors: [Int32] = []

        do {
            for lockURL in orderedURLs {
                let key = lockURL.path
                await TaskOperationLockGate.acquire(key)
                do {
                    let descriptor = try await Task.detached(priority: .utility) {
                        do {
                            try FileManager.default.createDirectory(
                                at: lockURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                        } catch {
                            throw BridgeFileLockError(message: "Couldn't create the \(purpose) lock directory: \(error.localizedDescription)")
                        }
                        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
                        guard descriptor >= 0 else {
                            throw BridgeFileLockError(message: "Couldn't open the \(purpose) lock (errno \(errno)).")
                        }
                        var lock = flock()
                        lock.l_type = Int16(F_WRLCK)
                        lock.l_whence = Int16(SEEK_SET)
                        while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
                            if errno == EACCES || errno == EAGAIN {
                                usleep(50_000)
                                continue
                            }
                            let code = errno
                            _ = Darwin.close(descriptor)
                            throw BridgeFileLockError(message: "Couldn't acquire the \(purpose) lock (errno \(code)).")
                        }
                        return descriptor
                    }.value
                    acquiredKeys.append(key)
                    descriptors.append(descriptor)
                } catch {
                    TaskOperationLockGate.release(key)
                    throw error
                }
            }
        } catch {
            for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }
            for key in acquiredKeys.reversed() { TaskOperationLockGate.release(key) }
            throw error
        }

        defer {
            for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }
            for key in acquiredKeys.reversed() { TaskOperationLockGate.release(key) }
        }
        return try await operation()
    }

    func list(status: TaskStatus? = nil) throws -> [BoardTaskRecord] {
        let descriptor: FetchDescriptor<BoardTask>
        if let status {
            let statusRawValue = status.rawValue
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.statusRawValue == statusRawValue },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        }
        let readFields = persistenceReadFields(operation: "BoardTaskManager.list")
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        StationAIDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            let tasks = try modelContext.fetch(descriptor).map { BoardTaskRecord(task: $0, includeDraftImages: false) }
            var fields = readFields
            fields["resultCount"] = String(tasks.count)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            StationAIDiagnostics.record("persistence.read.succeeded", fields: fields)
            return tasks
        } catch {
            var fields = persistenceReadFailureFields(error, context: readFields)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            StationAIDiagnostics.record("persistence.read.failed", fields: fields)
            throw error
        }
    }

    func get(_ id: UUID) throws -> BoardTaskRecord {
        BoardTaskRecord(task: try requireTask(id))
    }

    @discardableResult
    func create(title: String, workspaceRoots: [String]) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let normalizedRoots = try Self.normalizeRoots(workspaceRoots)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: normalizedRoots)
        modelContext.insert(task)
        try await saveTaskContext(taskID: task.id)
        StationAIDiagnostics.record("task.create.succeeded", fields: [
            "taskID": task.id.uuidString,
            "titleByteCount": String(normalizedTitle.utf8.count),
            "workspaceRootCount": String(normalizedRoots.count),
            "workspaceRoots": normalizedRoots.joined(separator: "\n"),
            "status": task.status.rawValue
        ])
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func create(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [String]) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let folders = try Self.normalizeOptionalRoots(contextFolders)
        var worktrees: [RepositoryWorktreeRecord] = []
        for spec in repositories {
            worktrees.append(try await worktreeService.pendingRecord(spec: spec))
        }
        let duplicate = worktrees.first { record in
            worktrees.filter { $0.repositoryPath == record.repositoryPath }.count > 1
        }
        if let duplicate {
            throw BridgeCommandError(code: "invalid_argument", message: "A repository can be selected only once per task: \(duplicate.repositoryPath)")
        }
        let roots = try Self.normalizeOptionalRoots(worktrees.map(\.repositoryPath) + folders)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: roots)
        task.repositoryWorktrees = worktrees
        task.contextFolderPaths = folders
        return try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
            try validateRepositoryAssignments(worktrees, excludingTaskID: nil)
            modelContext.insert(task)
            try await saveTaskContext(taskID: task.id)
            StationAIDiagnostics.record("task.create.succeeded", fields: [
                "taskID": task.id.uuidString,
                "titleByteCount": String(normalizedTitle.utf8.count),
                "repositoryCount": String(worktrees.count),
                "repositoryPaths": worktrees.map(\.repositoryPath).joined(separator: "\n"),
                "contextFolderCount": String(folders.count),
                "contextFolders": folders.joined(separator: "\n"),
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func addRepository(_ id: UUID, repositoryPath: String) async throws -> BoardTaskRecord {
        return try await addRepositories(id, repositoryPaths: [repositoryPath])
    }

    @discardableResult
    func addRepositories(_ id: UUID, repositoryPaths: [String]) async throws -> BoardTaskRecord {
        guard !repositoryPaths.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Add at least one repository.")
        }

        StationAIDiagnostics.record("workspace.repository.add.started", fields: [
            "taskID": id.uuidString,
            "repositoryCount": String(repositoryPaths.count),
            "repositoryPaths": repositoryPaths.joined(separator: "\n")
        ])

        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }

        var records: [RepositoryWorktreeRecord] = []
        records.reserveCapacity(repositoryPaths.count)
        for path in repositoryPaths {
            records.append(try await worktreeService.pendingRecord(
                spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
            ))
        }

        var seenRepositories = Set<String>()
        for record in records {
            let repository = Self.canonicalPath(record.repositoryPath)
            guard seenRepositories.insert(repository).inserted else {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "A repository can be selected only once per task: \(record.repositoryPath)"
                )
            }
        }

        let attachedRepositories = Set(initialTask.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
        if let duplicate = records.first(where: { attachedRepositories.contains(Self.canonicalPath($0.repositoryPath)) }) {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "This repository is already attached to the task: \(duplicate.repositoryPath)"
            )
        }

        return try await withConversationTurnReservation(id) {
            return try await withTaskOperationLock(id) {
                return try await withRepositoryAllocationLocks(records.map(\.repositoryPath)) {
                    let task = try requireTask(id)
                    guard task.status != .done else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
                    }

                    let currentRepositories = Set(task.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
                    if let duplicate = records.first(where: { currentRepositories.contains(Self.canonicalPath($0.repositoryPath)) }) {
                        throw BridgeCommandError(
                            code: "invalid_argument",
                            message: "This repository is already attached to the task: \(duplicate.repositoryPath)"
                        )
                    }
                    try validateRepositoryAssignments(records, excludingTaskID: id)

                    let repositories = task.repositoryWorktrees + records
                    let contextFolders = try Self.normalizeOptionalRoots(
                        task.contextFolderPaths.filter {
                            !seenRepositories.contains(Self.canonicalPath($0))
                        }
                    )
                    let roots = try Self.normalizeOptionalRoots(repositories.map { $0.isPending ? $0.repositoryPath : $0.worktreePath } + contextFolders)
                    task.repositoryWorktrees = repositories
                    task.contextFolderPaths = contextFolders
                    task.workspaceRootPaths = roots
                    try await saveTaskContext(taskID: id)
                    StationAIDiagnostics.record("workspace.repository.add.succeeded", fields: [
                        "taskID": id.uuidString,
                        "repositoryCount": String(records.count),
                        "repositoryPaths": records.map(\.repositoryPath).joined(separator: "\n")
                    ])
                    return BoardTaskRecord(task: task)
                }
            }
        }
    }

    @discardableResult
    func updateRepository(
        _ id: UUID,
        repositoryPath: String,
        branch: String,
        branchFrom: String,
        mergeTarget: String?
    ) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }
        guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branchFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Branch and merge-from values can't be empty.")
        }
        let initialRecord = try repositoryRecord(repositoryPath, in: initialTask)
        guard initialRecord.isPending else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repository settings are locked after the task starts.")
        }
        let validated = try await worktreeService.pendingRecord(
            spec: RepositoryWorktreeSpec(
                repositoryPath: initialRecord.repositoryPath,
                branch: branch,
                branchFrom: branchFrom,
                mergeTarget: mergeTarget
            )
        )

        return try await withConversationTurnReservation(id) {
            try await withTaskOperationLock(id) {
                try await withRepositoryAllocationLocks([validated.repositoryPath]) {
                    let task = try requireTask(id)
                    guard task.status != .done,
                          let index = task.repositoryWorktrees.firstIndex(where: { $0.repositoryPath == initialRecord.repositoryPath }),
                          task.repositoryWorktrees[index] == initialRecord else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repository settings changed while they were being validated. Try again.")
                    }
                    try validateRepositoryAssignments([validated], excludingTaskID: id)
                    var repositories = task.repositoryWorktrees
                    repositories[index] = validated
                    task.repositoryWorktrees = repositories
                    try await saveTaskContext(taskID: id)
                    return BoardTaskRecord(task: task)
                }
            }
        }
    }

    @discardableResult
    func removeRepository(_ id: UUID, repositoryPath: String) async throws -> BoardTaskRecord {
        return try await withConversationTurnReservation(id) {
            try await self.removeRepositoryWhileTurnReserved(id, repositoryPath: repositoryPath)
        }
    }

    private func removeRepositoryWhileTurnReserved(
        _ id: UUID,
        repositoryPath: String
    ) async throws -> BoardTaskRecord {
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status != .done else {
                throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
            }
            let record = try repositoryRecord(repositoryPath, in: task)
            let originalRepositories = task.repositoryWorktrees
            let originalRoots = task.workspaceRootPaths
            let updatedRepositories = originalRepositories.filter { $0.repositoryPath != record.repositoryPath }
            let roots = try Self.normalizeOptionalRoots(updatedRepositories.map(\.worktreePath) + task.contextFolderPaths)
            guard !roots.isEmpty || record.isPending else { throw StationAIManagerError.noWorkspaceRoots }
            let shouldRemoveWorktree = record.createdByStationAI && !record.isPending
                && FileManager.default.fileExists(atPath: record.worktreePath)

            return try await withRepositoryAllocationLocks([record.repositoryPath]) {
                let currentTask = try requireTask(id)
                guard currentTask.status != .done,
                      currentTask.repositoryWorktrees == originalRepositories,
                      currentTask.workspaceRootPaths == originalRoots else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its repository was being checked. Try again.")
                }
                if shouldRemoveWorktree, try await worktreeService.hasChanges(record) {
                    throw BridgeCommandError(
                        code: "operation_failed",
                        message: "Can't remove this repository because its worktree has uncommitted changes: \(record.worktreePath)"
                    )
                }

                currentTask.repositoryWorktrees = updatedRepositories
                currentTask.workspaceRootPaths = roots
                try await saveTaskContext(taskID: id)

                if shouldRemoveWorktree {
                    do {
                        try await worktreeService.remove(record)
                    } catch {
                        let removalError = error
                        guard let current = try? requireTask(id),
                              current.repositoryWorktrees == updatedRepositories,
                              current.workspaceRootPaths == roots else {
                            throw removalError
                        }
                        current.repositoryWorktrees = originalRepositories
                        current.workspaceRootPaths = originalRoots
                        do {
                            try await saveTaskContext(taskID: id)
                        } catch {
                            throw BridgeCommandError(
                                code: "operation_failed",
                                message: "Couldn't remove the repository worktree (\(removalError.localizedDescription)) or restore its task record (\(error.localizedDescription))."
                            )
                        }
                        throw removalError
                    }
                }
                return try get(id)
            }
        }
    }

    @discardableResult
    func move(
        _ id: UUID,
        to statusName: String,
        allowUnmergedPullRequests: Bool = false
    ) async throws -> BoardTaskRecord {
        StationAIDiagnostics.record("task.move.started", fields: [
            "taskID": id.uuidString,
            "requestedStatus": statusName,
            "allowUnmergedPullRequests": String(allowUnmergedPullRequests)
        ])
        guard let status = TaskStatus(rawValue: statusName) else {
            throw StationAIManagerError.invalidStatus(statusName)
        }
        guard status == .done else {
            throw StationAIManagerError.invalidTransition("Task status is controlled by Codex. Start or continue a conversation to update it.")
        }
        return try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            guard initialTask.status != .done else { return BoardTaskRecord(task: initialTask) }
            guard initialTask.status == .review else {
                throw StationAIManagerError.invalidTransition("Only a task in Review can move to Done.")
            }

            let originalRepositories = initialTask.repositoryWorktrees
            let linkedRecords = originalRepositories.filter { $0.pullRequestNumber != nil }
            if !linkedRecords.isEmpty && !allowUnmergedPullRequests {
                let executable = try pullRequestService.resolveExecutable()
                var unmerged: [RepositoryWorktreeRecord] = []
                for record in linkedRecords {
                    let isMerged = try await pullRequestService.isMerged(record, executable: executable)
                    if !isMerged { unmerged.append(record) }
                }
                if !unmerged.isEmpty {
                    throw StationAIManagerError.unmergedPullRequests(unmerged.compactMap(\.pullRequestNumber))
                }
            }
            let task = try requireTask(id)
            guard task.status == .review else {
                throw StationAIManagerError.invalidTransition("Only a task in Review can move to Done.")
            }
            guard task.repositoryWorktrees == originalRepositories else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task's pull request links changed while they were being checked. Try again.")
            }
            task.status = .done
            task.statusMessage = nil
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.move.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    func createPullRequests(_ id: UUID, client: CodexAppServerClient, conflictAction: String = "ask") async throws -> BoardTaskRecord {
        let conflicts = try await pullRequestConflictRepositories(id)
        if !conflicts.isEmpty {
            switch conflictAction {
            case "ask":
                throw BridgeCommandError(code: "conflicts_require_confirmation", message: "Pull request conflicts were found. Choose how to resolve them in StationAI.")
            case "keep":
                return try get(id)
            case "resolve-only":
                _ = try await resolvePullRequestConflicts(id, action: conflictAction, client: client)
                return try get(id)
            case "resolve-and-push":
                _ = try await resolvePullRequestConflicts(id, action: conflictAction, client: client)
            default:
                throw BridgeCommandError(code: "invalid_argument", message: "Unknown pull request conflict action '\(conflictAction)'.")
            }
        }
        let lookup = try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            let originalRecords = initialTask.repositoryWorktrees
            guard !originalRecords.isEmpty else {
                throw BridgeCommandError(code: "invalid_transition", message: "This task has no repository for a pull request.")
            }
            let gh = try pullRequestService.resolveExecutable()
            guard !originalRecords.contains(where: \.isPending) else {
                throw BridgeCommandError(code: "invalid_transition", message: "Start the task conversation before creating a pull request so its repository worktree is ready.")
            }
            var records = originalRecords
            for index in records.indices where records[index].pullRequestNumber == nil || records[index].pullRequestURL == nil {
                do {
                    // `--head` skips gh's push flow, and `gh pr list` also needs a
                    // published branch. Commit and publish before either GH request.
                    try await worktreeService.commitChanges(records[index], message: "Complete task: \(initialTask.title)")
                    try await worktreeService.publishBranch(records[index])
                } catch {
                    throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                }
                if let existing = try await pullRequestService.findOpen(records[index], executable: gh) {
                    records[index].pullRequestNumber = existing.number
                    records[index].pullRequestURL = existing.url
                }
            }
            let taskAfterLookup = try requireTask(id)
            guard taskAfterLookup.repositoryWorktrees == originalRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while pull requests were being checked. Try again.")
            }
            taskAfterLookup.repositoryWorktrees = records
            try await saveTaskContext(taskID: id)
            return (gh, records, BoardTaskRecord(task: taskAfterLookup))
        }
        let (gh, records, lookedUpRecords) = lookup
        guard records.contains(where: { $0.pullRequestNumber == nil || $0.pullRequestURL == nil }) else {
            return lookedUpRecords
        }

        let conversation = try await CodexConversationManager(tasks: self, client: client).history(taskID: id)
        let conversationText = conversation.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let currentTitle = try requireTask(id).title
        let summary: String
        if !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let roots = records.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) }
            let workspace = try CodexWorkspaceContext(roots: roots)
            let summaryThread = try await client.startThread(workspace: workspace, modelID: CodexAppServerClient.modelID)
            var generated = ""
            try await client.sendMessage(
                "Write a very concise GitHub pull request description. Explain what problem this change solves, how it solves it, and briefly mention any special issue or caveat from the conversation. Use Markdown, no more than three short sections, and return only the description.\n\nTask: \(currentTitle)\n\nConversation:\n\(conversationText)",
                mode: .plan,
                modelID: CodexAppServerClient.modelID,
                threadID: summaryThread,
                workspace: workspace,
                onDelta: { _ in },
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                onActionRequest: {}, onUserInput: { _ in }
            )
            guard !generated.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "Codex returned an empty pull request summary. Try again.")
            }
            summary = generated
        } else {
            summary = "Implements: \(currentTitle)."
        }

        let taskBeforeCreation = try requireTask(id)
        guard taskBeforeCreation.repositoryWorktrees == records,
              taskBeforeCreation.title == currentTitle else {
            throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
        }
        return try await withTaskOperationLock(id) {
            let taskAtCreation = try requireTask(id)
            guard taskAtCreation.repositoryWorktrees == records,
                  taskAtCreation.title == currentTitle else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
            }
            var updatedRecords = records
            var expectedRecords = records
            for index in updatedRecords.indices where updatedRecords[index].pullRequestNumber == nil || updatedRecords[index].pullRequestURL == nil {
                let record = updatedRecords[index]
                let pullRequest: GitHubPullRequestManager.PullRequest
                if let existing = try await pullRequestService.findOpen(record, executable: gh) {
                    pullRequest = existing
                } else {
                    do {
                        try await worktreeService.commitChanges(record, message: "Complete task: \(currentTitle)")
                        try await worktreeService.publishBranch(record)
                    } catch {
                        throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                    }
                    pullRequest = try await pullRequestService.create(record, title: currentTitle, body: summary, executable: gh)
                }
                updatedRecords[index].pullRequestNumber = pullRequest.number
                updatedRecords[index].pullRequestURL = pullRequest.url
                let currentTask = try requireTask(id)
                guard currentTask.repositoryWorktrees == expectedRecords else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while the pull request was being created.")
                }
                currentTask.repositoryWorktrees = updatedRecords
                try await saveTaskContext(taskID: id)
                expectedRecords = updatedRecords
            }
            return try get(id)
        }
    }

    func pullRequestConflictRepositories(_ id: UUID) async throws -> [String] {
        try await withTaskOperationLock(id) {
            try await pullRequestConflictRepositoriesUnlocked(id)
        }
    }

    func reviewPullRequests(_ id: UUID) async throws -> [PullRequestReviewState] {
        let task = try requireTask(id)
        let records = task.repositoryWorktrees.filter { !$0.isPending && $0.pullRequestNumber != nil }
        guard !records.isEmpty else { return [] }
        let executable = try pullRequestService.resolveExecutable()
        return try await withThrowingTaskGroup(of: PullRequestReviewState.self) { group in
            for record in records {
                group.addTask {
                    try await StationAIPullRequestService().reviewState(record, executable: executable)
                }
            }
            var states: [PullRequestReviewState] = []
            for try await state in group { states.append(state) }
            return states.sorted { $0.repositoryPath < $1.repositoryPath }
        }
    }

    func verifyPullRequestResolution(_ id: UUID) async throws -> PullRequestResolutionCheck {
        var latest: [PullRequestReviewState] = []
        for attempt in 0..<5 {
            latest = try await reviewPullRequests(id)
            if !latest.isEmpty && latest.allSatisfy(\.isConfirmedResolved) { return .resolved }
            if attempt < 4 { try await Task.sleep(for: .seconds(1)) }
        }
        guard !latest.isEmpty else { return .inconclusive }
        return latest.contains(where: {
            $0.hasConflicts || ($0.headRefOid != nil && $0.headRefOid != $0.localHeadOid)
        }) ? .stillConflicted : .inconclusive
    }

    private func pullRequestConflictRepositoriesUnlocked(_ id: UUID) async throws -> [String] {
        let task = try requireTask(id)
        guard !task.repositoryWorktrees.isEmpty else { return [] }
        var conflicts: [String] = []
        for record in task.repositoryWorktrees where !record.isPending && record.pullRequestNumber == nil {
            if try await worktreeService.hasMergeConflicts(record) { conflicts.append(record.repositoryPath) }
        }
        return conflicts
    }

    func resolvePullRequestConflicts(_ id: UUID, action: String, client: CodexAppServerClient) async throws -> BoardTaskRecord {
        guard ["resolve-and-push", "resolve-only", "keep"].contains(action) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose resolve-and-push, resolve-only, or keep.")
        }
        if action == "keep" { return try get(id) }
        return try await withTaskOperationLock(id) {
            let records = try requireTask(id).repositoryWorktrees.filter { !$0.isPending && $0.pullRequestNumber == nil }
            let conflicted = try await pullRequestConflictRepositoriesUnlocked(id)
            guard !conflicted.isEmpty else { return try get(id) }
            let affected = records.filter { conflicted.contains($0.repositoryPath) }
            let roots = try CodexWorkspaceContext(roots: affected.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) })
            for record in affected {
                guard let target = record.mergeTarget else { continue }
                // A prior Codex attempt may have left Git's merge in progress,
                // including after every conflict file was staged. Resume it.
                if try await worktreeService.hasMergeInProgress(record) == false {
                    try await worktreeService.mergeTarget(record, target: target)
                }
            }
            var finalMessage = ""
            var needsCodexResolution = false
            for record in affected {
                if try await worktreeService.hasUnmergedFiles(record) {
                    needsCodexResolution = true
                    break
                }
            }
            if needsCodexResolution {
                let thread = try await client.startThread(workspace: roots, modelID: CodexAppServerClient.modelID)
                do {
                    try await client.sendMessage(
                        "Resolve every Git merge conflict in the current workspace. Preserve the intended changes from both sides, inspect the resulting files, and stage the resolved files. Do not commit or push. Report which conflicts you resolved.",
                        mode: .code,
                        modelID: CodexAppServerClient.modelID,
                        threadID: thread,
                        workspace: roots,
                        onDelta: { _ in },
                        onFinalMessage: { finalMessage = $0 },
                        onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                        onActionRequest: {},
                        onUserInput: { request in
                            client.rejectUserInput(
                                requestID: request.id,
                                threadID: request.threadID,
                                message: "Conflict resolution cannot continue while Codex is waiting for user input."
                            )
                        }
                    )
                } catch {
                    for record in affected {
                        if try await worktreeService.hasUnmergedFiles(record) {
                            throw BridgeCommandError(code: "operation_failed", message: "Codex couldn't resolve every merge conflict. The task branch was left available for manual resolution.")
                        }
                    }
                    throw error
                }
            }
            for record in affected {
                guard try await worktreeService.hasUnmergedFiles(record) == false else {
                    throw BridgeCommandError(code: "operation_failed", message: "Codex couldn't resolve every merge conflict. The task branch was left available for manual resolution.")
                }
                try await worktreeService.commitChanges(record, message: "Resolve merge conflicts with \(record.mergeTarget ?? "target")")
                if action == "resolve-and-push" { try await worktreeService.publishBranch(record) }
            }
            StationAIDiagnostics.record("task.pr.conflicts.resolved", fields: [
                "taskID": id.uuidString, "repositoryCount": String(affected.count), "pushed": String(action == "resolve-and-push"),
                "hasCodexSummary": String(!finalMessage.isEmpty)
            ])
            return try get(id)
        }
    }

    func setLifecycleStatus(_ id: UUID, to status: TaskStatus, message: String? = nil) async throws -> BoardTaskRecord {
        StationAIDiagnostics.record("task.lifecycle_status.write.started", fields: [
            "taskID": id.uuidString,
            "status": status.rawValue,
            "hasStatusMessage": String(message != nil)
        ])
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status != .done else { return BoardTaskRecord(task: task) }
            task.status = status
            task.statusMessage = message
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    func reportTurnOutcome(_ id: UUID, outcome: String) async throws -> String {
        switch outcome {
        case "completed", "waiting-response": break
        default:
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Unknown turn outcome '\(outcome)'. Valid outcomes: completed, waiting-response."
            )
        }
        let outcomeURL = try conversationTurnOutcomeURL(id)
        let activeURL = try conversationTurnActiveURL(id)
        let lockURL = outcomeURL.appendingPathExtension("lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-outcome") {
            guard try self.hasConversationTurnReservation(id), FileManager.default.fileExists(atPath: activeURL.path) else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "Turn outcomes can only be reported during an active conversation turn."
                )
            }
            let task = try requireTask(id)
            guard task.status == .inProgress else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "Turn outcomes can only be reported while a task is In Progress."
                )
            }
            try Data(outcome.utf8).write(to: outcomeURL, options: .atomic)
            return outcome
        }
    }

    @discardableResult
    func publishProgressReport(_ id: UUID, type: TaskProgressType?, customLabel: String? = nil, detail: String? = nil) async throws -> BoardTaskRecord {
        let label = type?.label ?? customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty, label.count <= 60 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress labels must contain 1 to 60 characters.")
        }
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (normalizedDetail?.count ?? 0) <= 200 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress details must be 200 characters or fewer.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .inProgress else {
                throw BridgeCommandError(code: "invalid_transition", message: "Progress reports can only be published while a task is In Progress.")
            }
            task.progressTypeRawValue = type?.rawValue
            task.progressLabel = label
            task.progressDetail = normalizedDetail?.isEmpty == true ? nil : normalizedDetail
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    func recordConversationActivityDuration(taskID: UUID, activityID: String, durationMs: Int) async throws {
        guard !activityID.isEmpty, durationMs >= 0 else { return }
        try await withTaskOperationLock(taskID) {
            let task = try self.requireTask(taskID)
            var durations = (try? task.conversationActivityDurationsData.map {
                try JSONDecoder().decode([String: Int].self, from: $0)
            }) ?? [:]
            durations[activityID] = durationMs
            task.conversationActivityDurationsData = try? JSONEncoder().encode(durations)
            try await self.saveTaskContext(taskID: taskID)
        }
    }

    func conversationActivityDurations(taskID: UUID) -> [String: Int] {
        guard let task = try? requireTask(taskID), let data = task.conversationActivityDurationsData else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    @discardableResult
    func clearProgressReport(_ id: UUID) async throws -> BoardTaskRecord {
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    private func clearProgressReport(_ task: BoardTask) {
        task.progressTypeRawValue = nil
        task.progressLabel = nil
        task.progressDetail = nil
    }

    func reconcileLifecycleStatusOnOpen(_ id: UUID, client: CodexAppServerClient) async throws -> BoardTaskRecord {
        let currentTask = try requireTask(id)
        guard currentTask.codexThreadID != nil || currentTask.pendingSubmittedPrompt != nil else {
            return BoardTaskRecord(task: currentTask)
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard let threadID = task.codexThreadID else {
                if task.pendingSubmittedPrompt != nil, !(try hasConversationTurnReservation(id)) {
                    if task.status == .inProgress {
                        task.status = .blocked
                        task.statusMessage = "StationAI reopened before Codex started this turn. Review the prompt and retry."
                    }
                    task.pendingSubmittedPrompt = nil
                    try await saveTaskContext(taskID: id)
                }
                return BoardTaskRecord(task: task)
            }
            let hasActiveReservation = try hasConversationTurnReservation(id)
            guard !client.isTurnActive(threadID: threadID),
                  !CodexAppServerClient.isTurnActiveInProcess(threadID: threadID),
                  !hasActiveReservation else {
                return BoardTaskRecord(task: task)
            }
            let message: String
            switch task.status {
            case .inProgress:
                message = "StationAI reopened before Codex reported that this turn finished. Review the conversation and send a prompt to retry."
            case .waitingResponse:
                message = "StationAI reopened before the pending question was answered. Review the conversation and send a prompt to continue."
            default:
                return BoardTaskRecord(task: task)
            }
            task.status = .blocked
            task.statusMessage = message
            task.pendingSubmittedPrompt = nil
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    func resetAllTasksForLifecycle() async throws -> [String] {
        let all = try listModels()
        var dirtyManagedWorktrees: [String] = []
        for snapshot in all {
            let dirtyForTask = try await withTaskOperationLock(snapshot.id) { () async throws -> [String] in
                let task: BoardTask
                do {
                    task = try requireTask(snapshot.id)
                } catch let error as StationAIManagerError {
                    if case .taskNotFound = error { return [] }
                    throw error
                }
                var dirtyPaths: [String] = []
                for record in task.repositoryWorktrees where record.createdByStationAI {
                    guard FileManager.default.fileExists(atPath: record.worktreePath) else { continue }
                    if (try? await worktreeService.hasChanges(record)) != false {
                        dirtyPaths.append(record.worktreePath)
                    } else {
                        try await worktreeService.remove(record)
                    }
                }
                modelContext.delete(task)
                try await saveTaskContext(taskID: snapshot.id)
                return dirtyPaths
            }
            dirtyManagedWorktrees.append(contentsOf: dirtyForTask)
        }
        return dirtyManagedWorktrees
    }

    @discardableResult
    func rename(_ id: UUID, title: String) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        StationAIDiagnostics.record("task.rename.started", fields: [
            "taskID": id.uuidString,
            "titleByteCount": String(normalizedTitle.utf8.count)
        ])
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.title = normalizedTitle
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.rename.succeeded", fields: ["taskID": id.uuidString])
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func renameIfTitleMatches(_ id: UUID, expectedTitle: String, title: String) async throws -> BoardTaskRecord? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.title == expectedTitle else { return nil }
            let previousTitle = task.title
            task.title = normalizedTitle
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.title = previousTitle
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func savePrompt(_ id: UUID, prompt: String, status: TaskStatus? = nil, submitted: Bool = false, imageDataURLs: [String]? = nil) async throws -> BoardTaskRecord {
        StationAIDiagnostics.record("task.prompt.write.started", fields: [
            "taskID": id.uuidString,
            "promptByteCount": String(prompt.utf8.count),
            "status": status?.rawValue ?? "unchanged",
            "submitted": String(submitted)
        ])
        if let status, status != .backlog && status != .inProgress {
            throw StationAIManagerError.invalidTransition("Saving a task prompt can only place it in Backlog or Progress.")
        }
        if submitted, status != .inProgress {
            throw StationAIManagerError.invalidTransition("A submitted prompt must place the task in Progress.")
        }
        if let imageDataURLs, imageDataURLs.count > 8 || imageDataURLs.contains(where: { !CodexConversationManager.isValidImageDataURL($0) }) {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.savedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            if let imageDataURLs { task.draftImageDataURLs = imageDataURLs }
            task.pendingSubmittedPrompt = submitted ? prompt : nil
            if let status {
                task.status = status
                if status != .inProgress { clearProgressReport(task) }
            }
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.prompt.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue,
                "submitted": String(submitted)
            ])
            return BoardTaskRecord(task: task)
        }
    }

    func clearPendingSubmittedPrompt(_ id: UUID) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.pendingSubmittedPrompt != nil else { return }
            task.pendingSubmittedPrompt = nil
            try await saveTaskContext(taskID: id)
        }
    }

    func persistCodexThreadID(_ id: UUID, threadID: String) async throws -> BoardTaskRecord {
        guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Codex returned an empty thread ID.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.codexThreadID == nil || task.codexThreadID == threadID else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task is already linked to a different Codex conversation.")
            }
            guard task.codexThreadID != threadID else { return BoardTaskRecord(task: task) }
            task.codexThreadID = threadID
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.codexThreadID = nil
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func setWorkspaceRoots(_ id: UUID, roots: [String]) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        let initialRepositories = initialTask.repositoryWorktrees
        let initialWorkspaceRoots = initialTask.workspaceRootPaths
        let initialContextFolders = initialTask.contextFolderPaths
        if initialRepositories.isEmpty {
            let normalizedRoots = try Self.normalizeRoots(roots)
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    let task = try requireTask(id)
                    guard task.repositoryWorktrees == initialRepositories,
                          task.workspaceRootPaths == initialWorkspaceRoots,
                          task.contextFolderPaths == initialContextFolders else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                    }
                    task.workspaceRootPaths = normalizedRoots
                    task.contextFolderPaths = normalizedRoots
                    try await saveTaskContext(taskID: id)
                    return BoardTaskRecord(task: task)
                }
            }
        } else {
            let paths = try Self.normalizeOptionalRoots(roots)
            let existingPaths = Set(initialRepositories.map { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path })
            let retained = initialRepositories.filter { existingPaths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) && paths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) }
            var worktrees = retained
            var folders: [String] = []
            for path in paths where !existingPaths.contains(path) {
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) {
                    let record = try await worktreeService.pendingRecord(
                        spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
                    )
                    worktrees.append(record)
                } else {
                    folders.append(path)
                }
            }
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
                        let task = try requireTask(id)
                        guard task.repositoryWorktrees == initialRepositories,
                              task.workspaceRootPaths == initialWorkspaceRoots,
                              task.contextFolderPaths == initialContextFolders else {
                            throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                        }
                        try validateRepositoryAssignments(worktrees, excludingTaskID: id)
                        task.repositoryWorktrees = worktrees
                        task.contextFolderPaths = folders
                        let resolvedRoots = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + folders)
                        guard !resolvedRoots.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
                        task.workspaceRootPaths = resolvedRoots
                        try await saveTaskContext(taskID: id)
                        return BoardTaskRecord(task: task)
                    }
                }
            }
        }
    }

    func delete(_ id: UUID, diagnostics: [String: String] = [:]) async throws {
        try await withConversationTurnReservation(id) {
            try await self.deleteWhileTurnReserved(id, diagnostics: diagnostics)
        }
    }

    private func deleteWhileTurnReserved(_ id: UUID, diagnostics: [String: String]) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            try await withRepositoryAllocationLocks(task.repositoryWorktrees.map(\.repositoryPath)) {
                try await deleteTaskWhileLocked(task, diagnostics: diagnostics)
            }
        }
    }

    private func deleteTaskWhileLocked(_ task: BoardTask, diagnostics: [String: String]) async throws {
        var phase = "worktree-removal"
        var fields = [
            "taskID": task.id.uuidString,
            "taskStatus": task.status.rawValue,
            "threadID": task.codexThreadID ?? "",
            "worktreeCount": String(task.repositoryWorktrees.count),
            "storePath": StationAIDiagnostics.storeURL.path
        ]
        fields.merge(diagnostics) { _, new in new }
        StationAIDiagnostics.record("task.delete.started", fields: fields)
        do {
            for worktree in task.repositoryWorktrees {
                guard !worktree.isPending else { continue }
                fields["worktreePath"] = worktree.worktreePath
                StationAIDiagnostics.record("task.delete.worktree_removal_started", fields: fields)
                try await worktreeService.removeAfterConfirmation(worktree)
                StationAIDiagnostics.record("task.delete.worktree_removal_succeeded", fields: fields)
            }
            phase = "swiftdata-save"
            modelContext.delete(task)
            try await saveTaskContext(taskID: task.id)
            StationAIDiagnostics.record("task.delete.succeeded", fields: fields)
        } catch {
            fields["phase"] = phase
            fields.merge(
                StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            ) { _, new in new }
            StationAIDiagnostics.record("task.delete.failed", fields: fields)
            throw error
        }
    }

    func taskModel(_ id: UUID) throws -> BoardTask {
        try requireTask(id)
    }

    func prepareRepositoryWorktrees(_ id: UUID, fallbackPrompt: String? = nil) async throws -> BoardTask {
        let initialTask = try requireTask(id)
        let initialRecords = initialTask.repositoryWorktrees
        let pending = initialRecords.filter(\.isPending)
        guard !pending.isEmpty else { return initialTask }
        let branchTitle: String
        if ["Generating title…", "Untitled task"].contains(initialTask.title) {
            let prompt = initialTask.savedPrompt ?? fallbackPrompt ?? initialTask.title
            branchTitle = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        } else {
            branchTitle = initialTask.title
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.repositoryWorktrees == initialRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
            }
            return try await withRepositoryAllocationLocks(pending.map(\.repositoryPath)) {
                var resolved: [RepositoryWorktreeRecord] = []
                do {
                    try validateRepositoryAssignments(pending, excludingTaskID: id)
                    for item in pending {
                        let requestedBranch = item.branch == "auto" ? nil : item.branch
                        let record = try await worktreeService.resolve(
                            spec: RepositoryWorktreeSpec(
                                repositoryPath: item.repositoryPath,
                                branch: requestedBranch,
                                branchFrom: item.branchFrom,
                                mergeTarget: item.mergeTarget
                            ),
                            title: branchTitle,
                            root: worktreeRoot
                        )
                        resolved.append(record)
                    }
                    let currentTask = try requireTask(id)
                    guard currentTask.repositoryWorktrees == initialRecords else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
                    }
                    try validateRepositoryAssignments(resolved, excludingTaskID: id)
                    var iterator = resolved.makeIterator()
                    currentTask.repositoryWorktrees = currentTask.repositoryWorktrees.map { $0.isPending ? (iterator.next() ?? $0) : $0 }
                    currentTask.workspaceRootPaths = try Self.normalizeOptionalRoots(currentTask.repositoryWorktrees.map(\.worktreePath) + currentTask.contextFolderPaths)
                    try await saveTaskContext(taskID: id)
                    return currentTask
                } catch {
                    for record in resolved where record.createdByStationAI {
                        try? await worktreeService.remove(record)
                    }
                    throw error
                }
            }
        }
    }

    func deleteRequiresConfirmation(_ id: UUID) async throws -> Bool {
        let task = try requireTask(id)
        var dirtyWorktree = false
        for record in task.repositoryWorktrees where !record.isPending {
            if try await worktreeService.hasChanges(record) {
                dirtyWorktree = true
                break
            }
        }
        if dirtyWorktree { return true }
        let hasSavedConversation = task.codexThreadID != nil
            || !(task.savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return dirtyWorktree || hasSavedConversation
    }

    private func requireTask(_ id: UUID) throws -> BoardTask {
        var descriptor = FetchDescriptor<BoardTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let readFields = persistenceReadFields(operation: "BoardTaskManager.requireTask", taskID: id)
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        StationAIDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            guard let task = try modelContext.fetch(descriptor).first else {
                var fields = readFields
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
                StationAIDiagnostics.record("persistence.read.missing", fields: fields)
                throw StationAIManagerError.taskNotFound(id)
            }
            var fields = readFields
            fields["status"] = task.status.rawValue
            fields["repositoryCount"] = String(task.repositoryWorktrees.count)
            fields["workspaceRootCount"] = String(task.workspaceRootPaths.count)
            fields["hasCodexThread"] = String(task.codexThreadID != nil)
            fields["hasSavedPrompt"] = String(task.savedPrompt != nil)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            StationAIDiagnostics.record("persistence.read.succeeded", fields: fields)
            return task
        } catch {
            if !(error is StationAIManagerError) {
                var fields = persistenceReadFailureFields(error, context: readFields)
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
                StationAIDiagnostics.record("persistence.read.failed", fields: fields)
            }
            throw error
        }
    }

    private func persistenceReadFields(operation: String, taskID: UUID? = nil) -> [String: String] {
        let storeURL = modelContext.container.configurations.first?.url
        var fields = [
            "storePathAvailable": String(storeURL != nil)
        ]
        if let storeURL {
            fields["storePath"] = storeURL.standardizedFileURL.path
        }
        fields["readID"] = UUID().uuidString
        fields["operation"] = operation
        fields["entity"] = "BoardTask"
        if let taskID { fields["taskID"] = taskID.uuidString }
        return fields
    }

    private func persistenceReadFailureFields(_ error: Error, context: [String: String]) -> [String: String] {
        var fields = StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)
        fields.merge(context) { _, new in new }
        let storeURL = modelContext.container.configurations.first?.url
        fields.merge(StationAIDiagnostics.storeContextFields(for: storeURL)) {
            _, new in new
        }
        fields.merge(StationAIStore.schemaProbeFields(at: storeURL)) { _, new in new }
        return fields
    }

    private func validateRepositoryAssignments(
        _ candidates: [RepositoryWorktreeRecord],
        excludingTaskID: UUID?
    ) throws {
        for other in try listModels() where other.id != excludingTaskID && other.status != .done {
            for candidate in candidates {
                let repositoryPath = Self.canonicalPath(candidate.repositoryPath)
                if candidate.branch != "auto",
                   other.repositoryWorktrees.contains(where: {
                       Self.canonicalPath($0.repositoryPath) == repositoryPath && $0.branch == candidate.branch
                   }) {
                    throw StationAIManagerError.repositoryAssigned(candidate.repositoryPath)
                }

                let candidateWorkspacePath = Self.canonicalPath(
                    candidate.isPending ? candidate.repositoryPath : candidate.worktreePath
                )
                if other.repositoryWorktrees.contains(where: {
                    !$0.isPending && Self.canonicalPath($0.worktreePath) == candidateWorkspacePath
                }) {
                    throw StationAIManagerError.repositoryAssigned(candidateWorkspacePath)
                }
            }
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func repositoryRecord(_ path: String, in task: BoardTask) throws -> RepositoryWorktreeRecord {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let record = task.repositoryWorktrees.first(where: {
            URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == normalizedPath
        }) else {
            throw BridgeCommandError(code: "not_found", message: "This repository isn't attached to the task: \(normalizedPath)")
        }
        return record
    }

    private static func normalizeRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        guard !paths.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    private static func normalizeOptionalRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    private func listModels() throws -> [BoardTask] {
        let readFields = persistenceReadFields(operation: "BoardTaskManager.listModels")
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        StationAIDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            let tasks = try modelContext.fetch(FetchDescriptor<BoardTask>())
            var fields = readFields
            fields["resultCount"] = String(tasks.count)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            StationAIDiagnostics.record("persistence.read.succeeded", fields: fields)
            return tasks
        } catch {
            var fields = persistenceReadFailureFields(error, context: readFields)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            StationAIDiagnostics.record("persistence.read.failed", fields: fields)
            throw error
        }
    }

    private func saveTaskContext(operation: String = #function, taskID: UUID? = nil) async throws {
        let storeURL = modelContext.container.configurations.first?.url
        let writeID = UUID().uuidString
        let fields = [
            "writeID": writeID,
            "operation": operation,
            "entity": "BoardTask",
            "taskID": taskID?.uuidString ?? "",
            "storePath": storeURL?.path ?? "",
            "hasChanges": String(modelContext.hasChanges)
        ]
        StationAIDiagnostics.record("persistence.write.started", fields: fields)

        let lockWaitStartedAt = DispatchTime.now().uptimeNanoseconds
        var lockWaitMilliseconds = 0
        var lockAcquired = false
        var attemptCount = 0
        var retryCount = 0
        do {
            guard let storeURL else {
                throw BridgeFileLockError(message: "Couldn't determine the task-store location for a write lock.")
            }
            let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("store-write.lock")
            try await withExclusiveFileLocks(at: [lockURL], purpose: "task-store-write") {
                lockWaitMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - lockWaitStartedAt) / 1_000_000)
                lockAcquired = true
                var lockFields = fields
                lockFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                StationAIDiagnostics.record("persistence.write.lock_acquired", fields: lockFields)

                let retryDelays: [UInt64] = [100_000_000, 300_000_000, 600_000_000]
                while true {
                    attemptCount += 1
                    do {
                        try modelContext.save()
                        var successFields = fields
                        successFields["attemptCount"] = String(attemptCount)
                        successFields["retryCount"] = String(retryCount)
                        successFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                        StationAIDiagnostics.record("persistence.write.succeeded", fields: successFields)
                        return
                    } catch {
                        guard Self.isStoreOpenFailure(error), retryCount < retryDelays.count else {
                            throw error
                        }
                        let retryDelayMilliseconds = retryDelays[retryCount] / 1_000_000
                        var retryFields = StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)
                        retryFields.merge(fields) { _, new in new }
                        retryFields["attempt"] = String(attemptCount)
                        retryFields["retryCount"] = String(retryCount + 1)
                        retryFields["retryDelayMilliseconds"] = String(retryDelayMilliseconds)
                        retryFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                        StationAIDiagnostics.record("persistence.write.retry", fields: retryFields)
                        try await Task.sleep(nanoseconds: retryDelays[retryCount])
                        retryCount += 1
                    }
                }
            }
        } catch {
            var failureFields = StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)
            failureFields.merge(fields) { _, new in new }
            failureFields["attemptCount"] = String(attemptCount)
            failureFields["retryCount"] = String(retryCount)
            failureFields["lockWaitMilliseconds"] = String(lockAcquired
                ? lockWaitMilliseconds
                : Int((DispatchTime.now().uptimeNanoseconds - lockWaitStartedAt) / 1_000_000))
            StationAIDiagnostics.record("persistence.write.failed", fields: failureFields)
            throw error
        }
    }

}

@MainActor
final class WorkspaceSettingsManager {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        self.defaults = defaults
    }

    var defaultParentFolderPath: String {
        let value = defaults.string(forKey: WorkspaceSettings.defaultParentFolderKey) ?? ""
        StationAIDiagnostics.record("settings.read", fields: [
            "setting": "defaultParentFolder",
            "isSet": String(!value.isEmpty),
            "path": value
        ])
        return value
    }

    var lastSelectedRepositories: [String] {
        let value = defaults.stringArray(forKey: WorkspaceSettings.lastSelectedRepositoriesKey) ?? []
        StationAIDiagnostics.record("settings.read", fields: [
            "setting": "lastSelectedRepositories",
            "repositoryCount": String(value.count),
            "repositoryPaths": value.joined(separator: "\n")
        ])
        return value
    }

    var appearance: String {
        let value = defaults.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
        let appearance = value == "light" ? "light" : "dark"
        StationAIDiagnostics.record("settings.read", fields: ["setting": "appearance", "value": appearance])
        return appearance
    }

    var pullRequestConflictAction: String {
        let value = defaults.string(forKey: WorkspaceSettings.pullRequestConflictActionKey) ?? "ask"
        return ["ask", "resolve-and-push", "resolve-only", "keep"].contains(value) ? value : "ask"
    }

    func setPullRequestConflictAction(_ value: String) throws {
        guard ["ask", "resolve-and-push", "resolve-only", "keep"].contains(value) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Pull request conflict action must be ask, resolve-and-push, resolve-only, or keep.")
        }
        defaults.set(value, forKey: WorkspaceSettings.pullRequestConflictActionKey)
    }

    func setAppearance(_ value: String) throws {
        StationAIDiagnostics.record("settings.write.started", fields: ["setting": "appearance", "value": value])
        guard value == "dark" || value == "light" else {
            StationAIDiagnostics.record("settings.write.failed", fields: [
                "setting": "appearance",
                "value": value,
                "errorCode": "invalid_argument"
            ])
            throw BridgeCommandError(code: "invalid_argument", message: "Appearance must be 'dark' or 'light'.")
        }
        defaults.set(value, forKey: WorkspaceSettings.appearanceKey)
        StationAIDiagnostics.record("settings.write.succeeded", fields: ["setting": "appearance", "value": value])
    }

    var defaultParentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    func setDefaultParentFolder(_ path: String?) throws {
        StationAIDiagnostics.record("settings.write.started", fields: [
            "setting": "defaultParentFolder",
            "path": path ?? "",
            "cleared": String(path == nil || path?.isEmpty == true)
        ])
        guard let path, !path.isEmpty else {
            defaults.removeObject(forKey: WorkspaceSettings.defaultParentFolderKey)
            StationAIDiagnostics.record("settings.write.succeeded", fields: [
                "setting": "defaultParentFolder",
                "cleared": "true"
            ])
            return
        }
        guard let url = WorkspaceSettings.validDirectoryURL(for: path) else {
            StationAIDiagnostics.record("settings.write.failed", fields: [
                "setting": "defaultParentFolder",
                "path": path,
                "errorCode": "invalid_argument"
            ])
            throw StationAIManagerError.invalidParentFolder(path)
        }
        defaults.set(url.path, forKey: WorkspaceSettings.defaultParentFolderKey)
        StationAIDiagnostics.record("settings.write.succeeded", fields: [
            "setting": "defaultParentFolder",
            "path": url.path,
            "cleared": "false"
        ])
    }

    func setLastSelectedRepositories(_ paths: [String]) throws {
        StationAIDiagnostics.record("settings.write.started", fields: [
            "setting": "lastSelectedRepositories",
            "requestedCount": String(paths.count),
            "requestedPaths": paths.joined(separator: "\n")
        ])
        var normalized: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                StationAIDiagnostics.record("settings.write.failed", fields: [
                    "setting": "lastSelectedRepositories",
                    "path": path,
                    "errorCode": "invalid_argument"
                ])
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            if !normalized.contains(url.path) { normalized.append(url.path) }
        }
        defaults.set(normalized, forKey: WorkspaceSettings.lastSelectedRepositoriesKey)
        StationAIDiagnostics.record("settings.write.succeeded", fields: [
            "setting": "lastSelectedRepositories",
            "repositoryCount": String(normalized.count),
            "repositoryPaths": normalized.joined(separator: "\n")
        ])
    }
}

@MainActor
final class WorkspaceManager {
    private let taskManager: BoardTaskManager?

    init(taskManager: BoardTaskManager? = nil) {
        self.taskManager = taskManager
    }

    func suggestedRepositories(parentPath: String) async throws -> [String] {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: parentPath) else {
            throw StationAIManagerError.invalidParentFolder(parentPath)
        }
        StationAIDiagnostics.record("workspace.repositories.scan.started", fields: ["parentPath": parent.path])
        let repositories = await RepositoryScanner.scan(parent: parent).map(\.path)
        StationAIDiagnostics.record("workspace.repositories.scan.succeeded", fields: [
            "parentPath": parent.path,
            "repositoryCount": String(repositories.count),
            "repositories": repositories.joined(separator: "\n")
        ])
        return repositories
    }

    func roots(for taskID: UUID) throws -> [String] {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.roots.read.started", fields: ["taskID": taskID.uuidString])
        let roots = try taskManager.get(taskID).workspaceRoots
        StationAIDiagnostics.record("workspace.roots.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "rootCount": String(roots.count),
            "roots": roots.joined(separator: "\n")
        ])
        return roots
    }

    @discardableResult
    func setRoots(_ roots: [String], for taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.roots.write.started", fields: [
            "taskID": taskID.uuidString,
            "requestedRoots": roots.joined(separator: "\n"),
            "requestedRootCount": String(roots.count)
        ])
        let record = try await taskManager.setWorkspaceRoots(taskID, roots: roots)
        StationAIDiagnostics.record("workspace.roots.write.succeeded", fields: [
            "taskID": taskID.uuidString,
            "rootCount": String(record.workspaceRoots.count),
            "roots": record.workspaceRoots.joined(separator: "\n")
        ])
        return record
    }

    @discardableResult
    func addRepository(_ repositoryPath: String, to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.repository.add.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repositoryPath
        ])
        let record = try await taskManager.addRepository(taskID, repositoryPath: repositoryPath)
        StationAIDiagnostics.record("workspace.repository.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repositoryPath,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return record
    }

    @discardableResult
    func addRepositories(_ repositoryPaths: [String], to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.repositories.add.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPaths": repositoryPaths.joined(separator: "\n"),
            "repositoryCount": String(repositoryPaths.count)
        ])
        let record = try await taskManager.addRepositories(taskID, repositoryPaths: repositoryPaths)
        StationAIDiagnostics.record("workspace.repositories.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return record
    }

    func changes(for taskID: UUID) async throws -> WorkspaceChangeInventory {
        guard taskManager != nil else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        StationAIDiagnostics.record("workspace.changes.read.started", fields: ["taskID": taskID.uuidString])
        let inventory = try await WorkspaceChangeScanner.inventory(workspaceRoots: roots(for: taskID))
        StationAIDiagnostics.record("workspace.changes.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "stagedCount": String(inventory.staged.count),
            "workingCount": String(inventory.working.count)
        ])
        return inventory
    }

    func diff(
        for taskID: UUID,
        repository: String,
        path: String,
        group: String
    ) async throws -> WorkspaceFileDiff {
        guard taskManager != nil else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        guard let changeGroup = WorkspaceChangeGroup(rawValue: group) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Change group must be 'staged' or 'working'.")
        }
        StationAIDiagnostics.record("workspace.diff.read.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repository,
            "path": path,
            "group": group
        ])
        let fileDiff = try await WorkspaceChangeScanner.diff(
            workspaceRoots: roots(for: taskID),
            repositoryPath: repository,
            relativePath: path,
            group: changeGroup
        )
        StationAIDiagnostics.record("workspace.diff.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repository,
            "path": path,
            "group": group,
            "originalBytes": String(fileDiff.original?.utf8.count ?? 0),
            "modifiedBytes": String(fileDiff.modified?.utf8.count ?? 0),
            "isText": String(fileDiff.isText)
        ])
        return fileDiff
    }
}

struct ConversationUpdate: Codable {
    let type: String
    var text: String?
    var itemID: String?
    var phase: String?
    var activity: CodexActivity?
    var diff: String?
    var history: CodexThreadHistory?
    var message: String?
    var imageDataURLs: [String]?
    var userInputRequest: CodexUserInputRequest?
    var taskStatus: String?
}

@MainActor
final class CodexConversationManager {
    private let tasks: BoardTaskManager
    private let client: CodexAppServerClient
    private static var dispatchingQueuedTaskIDs = Set<UUID>()
    private static var pendingQueuedTaskDispatchIDs = Set<UUID>()
    private var activeSendTaskIDs = Set<UUID>()

    private func shouldDrainMissedSteerImmediately(taskID: UUID) -> Bool {
        guard !activeSendTaskIDs.contains(taskID) else { return false }
        return (try? tasks.hasConversationTurnReservation(taskID)) != true
    }

    init(tasks: BoardTaskManager, client: CodexAppServerClient) {
        self.tasks = tasks
        self.client = client
        if let directory = try? tasks.conversationSteerMailboxDirectory() {
            CodexAppServerClient.configureSteerMailbox(directory: directory)
        }
    }

    func history(taskID: UUID, onActionRequest: @escaping () -> Void = {}) async throws -> CodexThreadHistory {
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.codexThreadID else {
            return CodexThreadHistory(messages: [], activities: [], diff: nil)
        }
        let historyRoots = task.workspaceRootPaths.isEmpty && task.status == .done
            ? task.repositoryWorktrees.map { $0.repositoryPath }
            : task.workspaceRootPaths
        let workspace = try CodexWorkspaceContext(roots: historyRoots.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        StationAIDiagnostics.record("conversation.history.started", fields: client.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "taskStatus": task.status.rawValue
        ]))
        do {
            let history = try await client.loadThread(
                id: threadID,
                workspace: workspace,
                developerInstructions: TaskProgressReportInstructions.make(taskID: taskID),
                onActionRequest: onActionRequest
            )
            let savedDurations = tasks.conversationActivityDurations(taskID: taskID)
            let activities = history.activities.map { activity -> CodexActivity in
                var activity = activity
                if activity.durationMs == nil { activity.durationMs = savedDurations[activity.id] }
                return activity
            }
            StationAIDiagnostics.record("conversation.history.succeeded", fields: client.diagnosticFields([
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "messageCount": String(history.messages.count),
                "activityCount": String(history.activities.count)
            ]))
            return CodexThreadHistory(messages: history.messages, activities: activities, diff: history.diff)
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["taskStatus"] = task.status.rawValue
            fields.merge(client.diagnosticFields()) { _, new in new }
            StationAIDiagnostics.record("conversation.history.failed", fields: fields)
            throw error
        }
    }

    func searchArchive(query: String, codexHomePath: String? = nil) async throws -> [BoardTaskRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Archive search query can't be blank.")
        }
        let completed = try tasks.list(status: .done)
        let titleMatches = completed.filter { $0.title.localizedCaseInsensitiveContains(normalizedQuery) }
        let titleIDs = Set(titleMatches.map(\.id))
        let root: URL
        if let codexHomePath, !codexHomePath.isEmpty {
            root = URL(fileURLWithPath: codexHomePath, isDirectory: true)
        } else if let environmentRoot = ProcessInfo.processInfo.environment["CODEX_HOME"], !environmentRoot.isEmpty {
            root = URL(fileURLWithPath: environmentRoot, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        let roots = [root.appendingPathComponent("sessions", isDirectory: true), root.appendingPathComponent("archived_sessions", isDirectory: true)]
        let taskByThread = Dictionary(completed.compactMap { task -> (String, UUID)? in
            guard !titleIDs.contains(task.id), let threadID = task.codexThreadID else { return nil }
            return (threadID, task.id)
        }, uniquingKeysWith: { first, _ in first })
        let scanTask = Task.detached(priority: .userInitiated) {
            try Self.searchSessionFiles(query: normalizedQuery, taskByThread: taskByThread, roots: roots)
        }
        let conversationIDs = try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        let byID = Dictionary(uniqueKeysWithValues: completed.map { ($0.id, $0) })
        let titles = titleMatches.sorted { $0.createdAt > $1.createdAt }
        let conversations = conversationIDs.compactMap { byID[$0] }.sorted { $0.createdAt > $1.createdAt }
        return titles + conversations
    }

    nonisolated private static func searchSessionFiles(query: String, taskByThread: [String: UUID], roots: [URL]) throws -> Set<UUID> {
        var filesByThread: [String: [URL]] = [:]
        for sessionsRoot in roots {
            guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                try Task.checkCancellation()
                let basename = fileURL.deletingPathExtension().lastPathComponent
                guard let threadID = taskByThread.keys.first(where: { basename.hasSuffix("-\($0)") }) else { continue }
                filesByThread[threadID, default: []].append(fileURL)
            }
        }
        var conversationIDs = Set<UUID>()
        for (threadID, taskID) in taskByThread {
            for fileURL in filesByThread[threadID] ?? [] {
                try Task.checkCancellation()
                if try sessionFile(fileURL, contains: query) {
                    conversationIDs.insert(taskID)
                    break
                }
            }
        }
        return conversationIDs
    }

    nonisolated private static func sessionFile(_ url: URL, contains query: String) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var pending = Data()
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let line = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                if Self.messageText(in: line).contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }) { return true }
            }
        }
        if !pending.isEmpty, Self.messageText(in: pending).contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }) { return true }
        return false
    }

    nonisolated private static func messageText(in line: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return [] }
        if type == "response_item", let itemType = payload["type"] as? String, itemType == "message",
           let role = payload["role"] as? String, role == "user" || role == "assistant",
           let content = payload["content"] as? [[String: Any]] {
            let searchableTextTypes: Set<String> = ["text", "input_text", "output_text"]
            return content.compactMap {
                guard let contentType = $0["type"] as? String, searchableTextTypes.contains(contentType) else { return nil }
                return $0["text"] as? String
            }
        }
        if type == "event_msg", let eventType = payload["type"] as? String,
           eventType == "UserMessage" || eventType == "AgentMessage",
           let message = payload["message"] as? String { return [message] }
        return []
    }

    func models(taskID: UUID) async throws -> [CodexModelOption] {
        StationAIDiagnostics.record("codex.models.read.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.taskModel(taskID)
        let workspace = try CodexWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let models = try await client.availableModels(workspace: workspace)
        StationAIDiagnostics.record("codex.models.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "modelCount": String(models.count),
            "modelIDs": models.map(\.id).joined(separator: ",")
        ])
        return models
    }

    func interrupt(taskID: UUID) async throws -> Bool {
        StationAIDiagnostics.record("conversation.interrupt.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.codexThreadID else {
            StationAIDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_thread"
            ])
            return false
        }
        let interrupted = try await client.interruptActiveTurn(threadID: threadID)
        StationAIDiagnostics.record("conversation.interrupt.finished", fields: [
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "interrupted": String(interrupted)
        ])
        return interrupted
    }

    func steer(taskID: UUID, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.codexThreadID else { return false }
        return try await client.steerActiveTurn(threadID: threadID, text: normalizedText, imageDataURLs: imageDataURLs)
    }

    func queuedMessages(taskID: UUID) throws -> [QueuedConversationMessage] {
        try tasks.queuedConversationMessages(taskID: taskID)
    }

    func queueMessage(taskID: UUID, text: String, imageDataURLs: [String] = []) throws -> QueuedConversationMessage {
        return try tasks.enqueueConversationMessage(
            taskID: taskID,
            text: text, imageDataURLs: imageDataURLs
        )
    }

    func queueMissedSteer(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (CodexUserInputRequest) async -> Void = { _ in }
    ) async throws -> QueuedConversationMessage {
        let item = try queueMessage(taskID: taskID, text: text, imageDataURLs: imageDataURLs)
        if shouldDrainMissedSteerImmediately(taskID: taskID) {
            await dispatchQueuedMessages(
                taskID: taskID,
                mode: .code,
                modelID: CodexAppServerClient.modelID,
                onlyMessageID: item.id,
                onUpdate: onUpdate,
                onUserInput: onUserInput
            )
        } else if Self.dispatchingQueuedTaskIDs.contains(taskID) {
            Self.pendingQueuedTaskDispatchIDs.insert(taskID)
        }
        return item
    }

    func removeQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try tasks.removeQueuedMessage(taskID: taskID, messageID: messageID)
    }

    func steerQueuedMessage(taskID: UUID, messageID: UUID) async throws -> (message: String, accepted: Bool) {
        let item = try tasks.queuedConversationMessages(taskID: taskID).first { $0.id == messageID }
        guard let item, item.state == .queued else {
            throw BridgeCommandError(code: "invalid_transition", message: "That follow-up is no longer available to steer.")
        }
        try tasks.reserveQueuedMessageForSteering(taskID: taskID, messageID: messageID)
        do {
            let accepted = try await steer(taskID: taskID, text: item.text, imageDataURLs: item.imageDataURLs ?? [])
            if accepted { try tasks.finishQueuedMessageSteering(taskID: taskID, messageID: messageID, accepted: true) }
            else {
                try tasks.requeueMissedSteer(taskID: taskID, messageID: messageID)
                if shouldDrainMissedSteerImmediately(taskID: taskID) {
                    await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: CodexAppServerClient.modelID, onlyMessageID: messageID, onUpdate: { _ in }, onUserInput: { _ in })
                } else if Self.dispatchingQueuedTaskIDs.contains(taskID) {
                    Self.pendingQueuedTaskDispatchIDs.insert(taskID)
                }
            }
            return (item.text, accepted)
        } catch {
            try? tasks.finishQueuedMessageSteering(taskID: taskID, messageID: messageID, accepted: false)
            throw error
        }
    }

    func retryQueuedMessage(
        taskID: UUID,
        messageID: UUID,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (CodexUserInputRequest) async -> Void = { _ in }
    ) async throws -> Bool {
        try tasks.retryQueuedMessage(taskID: taskID, messageID: messageID)
        await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: CodexAppServerClient.modelID, onlyMessageID: messageID, onUpdate: onUpdate, onUserInput: onUserInput)
        return try !tasks.queuedConversationMessages(taskID: taskID).contains { $0.id == messageID }
    }

    func send(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        mode: CodexConversationMode = .code,
        modelID: String = CodexAppServerClient.modelID,
        userInputAnswers: [String: [String]] = [:],
        retainQueuedMessagesOnFailure: Bool = true,
        onTurnStarting: (() -> Void)? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (CodexUserInputRequest) async -> Void = { _ in }
    ) async throws -> CodexThreadHistory {
        activeSendTaskIDs.insert(taskID)
        defer { activeSendTaskIDs.remove(taskID) }
        let history: CodexThreadHistory
        do {
            history = try await tasks.withConversationTurnReservation(taskID) {
                do {
                    let result = try await self.sendReserved(
                        taskID: taskID,
                        text: text,
                        imageDataURLs: imageDataURLs,
                        mode: mode,
                        modelID: modelID,
                        userInputAnswers: userInputAnswers,
                        onTurnStarting: onTurnStarting,
                        onUpdate: onUpdate,
                        onUserInput: onUserInput
                    )
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    return result
                } catch {
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    throw error
                }
            }
        } catch {
            if retainQueuedMessagesOnFailure, let threadID = try? tasks.taskModel(taskID).codexThreadID {
                try? tasks.retainQueuedMessagesForUserAction(taskID: taskID, threadID: threadID)
                onUpdate(ConversationUpdate(type: "queue_changed"))
            }
            throw error
        }
        if !Self.dispatchingQueuedTaskIDs.contains(taskID) {
            await dispatchQueuedMessages(taskID: taskID, mode: mode, modelID: modelID, onUpdate: onUpdate, onUserInput: onUserInput)
        }
        return history
    }

    private func dispatchQueuedMessages(
        taskID: UUID,
        mode: CodexConversationMode,
        modelID: String,
        onlyMessageID: UUID? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (CodexUserInputRequest) async -> Void
    ) async {
        let threadID: String
        do {
            guard let value = try tasks.taskModel(taskID).codexThreadID else { return }
            threadID = value
        } catch { return }
        guard Self.dispatchingQueuedTaskIDs.insert(taskID).inserted else {
            Self.pendingQueuedTaskDispatchIDs.insert(taskID)
            return
        }
        var dispatchEncounteredFailure = false
        defer { Self.dispatchingQueuedTaskIDs.remove(taskID) }
        var messageIDFilter = onlyMessageID
        while true {
            while true {
                let item: QueuedConversationMessage?
                do { item = try tasks.claimNextQueuedMessage(taskID: taskID, threadID: threadID, messageID: messageIDFilter) }
                catch { break }
                guard let item else { break }
                do {
                    _ = try await send(
                        taskID: taskID,
                        text: item.text,
                        imageDataURLs: item.imageDataURLs ?? [],
                        mode: mode,
                        modelID: modelID,
                        retainQueuedMessagesOnFailure: false,
                        onUpdate: onUpdate,
                        onUserInput: onUserInput
                    )
                    try tasks.finishQueuedMessage(item, succeeded: true)
                    onUpdate(ConversationUpdate(type: "queue_changed"))
                } catch {
                    dispatchEncounteredFailure = true
                    try? tasks.finishQueuedMessage(item, succeeded: false)
                    onUpdate(ConversationUpdate(type: "queue_changed"))
                    onUpdate(ConversationUpdate(type: "action_notice", message: "A queued follow-up needs your review before it can be retried."))
                    break
                }
            }
            guard !dispatchEncounteredFailure else { break }
            let hadPendingDispatch = Self.pendingQueuedTaskDispatchIDs.remove(taskID) != nil
            let hasQueuedFollowUp = messageIDFilter != nil &&
                ((try? tasks.queuedConversationMessages(taskID: taskID).contains { $0.state == .queued }) == true)
            guard hadPendingDispatch || hasQueuedFollowUp else { break }
            messageIDFilter = nil
        }
    }

    private func sendReserved(
        taskID: UUID,
        text: String,
        imageDataURLs: [String],
        mode: CodexConversationMode,
        modelID: String,
        userInputAnswers: [String: [String]],
        onTurnStarting: (() -> Void)?,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (CodexUserInputRequest) async -> Void
    ) async throws -> CodexThreadHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        try tasks.prepareConversationTurnOutcome(taskID)
        defer { tasks.clearConversationTurnOutcome(taskID) }
        var task = try tasks.taskModel(taskID)
        var persistedThreadID = task.codexThreadID
        StationAIDiagnostics.record("conversation.send.started", fields: client.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": task.codexThreadID ?? "new",
            "taskStatus": task.status.rawValue,
            "mode": mode.rawValue
        ]))
        defer {
            if let threadID = persistedThreadID {
                client.clearTurnStarting(threadID: threadID)
            }
        }
        guard task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task for follow-up work.")
        }
        let shouldGenerateTitle = !normalizedText.isEmpty && ["Untitled task", "Generating title…"].contains(task.title)
        _ = try await tasks.savePrompt(taskID, prompt: normalizedText, status: .inProgress, submitted: true)
        let titleMustPrecedeAutoWorktree = task.repositoryWorktrees.contains {
            $0.isPending && $0.branch == "auto"
        }
        let resolveTitleBeforeWorktree = shouldGenerateTitle && titleMustPrecedeAutoWorktree
        if resolveTitleBeforeWorktree {
            let reserved = try await tasks.renameIfTitleMatches(
                taskID,
                expectedTitle: task.title,
                title: "Generating title…"
            )
            if reserved != nil {
                let titleRoots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                let titleWorkspace = try CodexWorkspaceContext(roots: titleRoots)
                let titleClient = CodexAppServerClient(
                    codexExecutableOverride: client.executableOverrideForTitleGeneration
                )
                try await generateAndApplyTitle(
                    taskID: taskID,
                    prompt: normalizedText,
                    workspace: titleWorkspace,
                    client: titleClient
                )
            }
            task = try tasks.taskModel(taskID)
            if ["Untitled task", "Generating title…"].contains(task.title) {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "The task title changed while it was being prepared. Try sending again."
                )
            }
        }
        task = try await tasks.prepareRepositoryWorktrees(taskID, fallbackPrompt: normalizedText)
        if !normalizedText.isEmpty {
            _ = try await tasks.savePrompt(taskID, prompt: normalizedText, status: .inProgress, submitted: true)
        }
        let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let workspace = try CodexWorkspaceContext(roots: roots)
        _ = try await tasks.clearProgressReport(taskID)
        let titleGeneration: Task<Void, Never>?
        if shouldGenerateTitle && !resolveTitleBeforeWorktree {
            let latest = try tasks.taskModel(taskID)
            let titleReserved = ["Untitled task", "Generating title…"].contains(latest.title)
                ? try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: latest.title,
                    title: "Generating title…"
                ) != nil
                : false
            if titleReserved {
                titleGeneration = Task { @MainActor in
                    let titleClient = CodexAppServerClient(
                        codexExecutableOverride: self.client.executableOverrideForTitleGeneration
                    )
                    do {
                        try await self.generateAndApplyTitle(
                            taskID: taskID,
                            prompt: normalizedText,
                            workspace: workspace,
                            client: titleClient
                        )
                    } catch {
                        // Background title generation has always been best-effort;
                        // the helper records persistence failures before returning.
                    }
                }
            } else {
                titleGeneration = nil
            }
        } else {
            titleGeneration = nil
        }
        let started = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
        onUpdate(ConversationUpdate(type: "started", taskStatus: started.status))
        var phase = "thread-start"
        do {
            let threadID: String
            if let existing = task.codexThreadID {
                threadID = existing
            } else {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: TaskProgressReportInstructions.make(taskID: taskID)
                )
                phase = "thread-persistence"
                _ = try await tasks.persistCodexThreadID(taskID, threadID: threadID)
                persistedThreadID = threadID
            }
            if onTurnStarting != nil {
                client.markTurnStarting(threadID: threadID)
                onTurnStarting?()
            }
            phase = "codex-turn"
            try tasks.activateConversationTurnOutcome(taskID)
            try await client.sendMessage(
                normalizedText,
                imageDataURLs: imageDataURLs,
                mode: mode,
                modelID: modelID,
                threadID: threadID,
                workspace: workspace,
                developerInstructions: TaskProgressReportInstructions.make(taskID: taskID),
                onDelta: { delta in onUpdate(ConversationUpdate(type: "text_delta", text: delta)) },
                onFinalMessage: { message in onUpdate(ConversationUpdate(type: "assistant_final", text: message)) },
                onActivity: { activity in
                    if let durationMs = activity.durationMs {
                        Task { @MainActor in
                            try? await self.tasks.recordConversationActivityDuration(
                                taskID: taskID,
                                activityID: activity.id,
                                durationMs: durationMs
                            )
                        }
                    }
                    onUpdate(ConversationUpdate(type: "activity", activity: activity))
                },
                onDiff: { diff in onUpdate(ConversationUpdate(type: "diff", diff: diff.unifiedDiff)) },
                onHistory: { history in onUpdate(ConversationUpdate(type: "history", history: history)) },
                onActionRequest: {
                    let message = "Codex requested an approval. StationAI denied it because approval prompts are disabled."
                    onUpdate(ConversationUpdate(type: "action_notice", message: message))
                },
                onUserInput: { request async in
                    let status: BoardTaskRecord?
                    if request.isBlocking {
                        status = try? await self.tasks.setLifecycleStatus(taskID, to: .waitingResponse)
                    } else {
                        status = try? await self.tasks.clearProgressReport(taskID)
                    }
                    onUpdate(ConversationUpdate(
                        type: "user_input",
                        userInputRequest: request,
                        taskStatus: status?.status
                    ))
                    if !userInputAnswers.isEmpty {
                        let answersAccepted = self.client.answerUserInput(
                            requestID: request.id,
                            threadID: request.threadID,
                            answers: userInputAnswers
                        )
                        if answersAccepted, request.isBlocking {
                            let resumed = try? await self.tasks.setLifecycleStatus(taskID, to: .inProgress)
                            onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed?.status))
                        } else if !answersAccepted {
                            onUpdate(ConversationUpdate(type: "action_notice", message: "The supplied answers didn't match Codex's questions."))
                        }
                    }
                    await onUserInput(request)
                },
                onSteerMessage: { message, images in
                    onUpdate(ConversationUpdate(type: "steered_message", message: message, imageDataURLs: images))
                },
                onProgressMessage: { message in
                    onUpdate(ConversationUpdate(
                        type: "assistant_progress",
                        text: message.text,
                        itemID: message.id,
                        phase: message.phase
                    ))
                }
            )
            for (activityID, durationMs) in client.lastTurnActivityDurations {
                try await tasks.recordConversationActivityDuration(
                    taskID: taskID,
                    activityID: activityID,
                    durationMs: durationMs
                )
            }
            phase = "worktree-finalization"
            phase = "review-status-persistence"
            let reportedOutcome = try await tasks.finishConversationTurnOutcome(taskID)
            let finalStatus: TaskStatus = reportedOutcome == "completed" ? .review : .waitingResponse
            _ = try await tasks.setLifecycleStatus(taskID, to: finalStatus)
        } catch {
            await titleGeneration?.value
            for (activityID, durationMs) in client.lastTurnActivityDurations {
                try? await tasks.recordConversationActivityDuration(
                    taskID: taskID,
                    activityID: activityID,
                    durationMs: durationMs
                )
            }
            var fields = StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = persistedThreadID ?? ""
            fields["phase"] = phase
            fields["storePath"] = StationAIDiagnostics.storeURL.path
            fields.merge(client.diagnosticFields()) { _, new in new }
            _ = try? await tasks.setLifecycleStatus(taskID, to: .blocked, message: error.localizedDescription)
            StationAIDiagnostics.record("conversation.send.failed", fields: fields)
            throw error
        }
        await titleGeneration?.value
        let finalHistory = try await history(taskID: taskID) {
            onUpdate(ConversationUpdate(
                type: "action_notice",
                message: "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            ))
        }
        onUpdate(ConversationUpdate(type: "completed", history: finalHistory))
        return finalHistory
    }

    private func generateAndApplyTitle(
        taskID: UUID,
        prompt: String,
        workspace: CodexWorkspaceContext,
        client titleClient: CodexAppServerClient
    ) async throws {
        let generated = await CodexTaskTitleGenerator(client: titleClient)
            .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
        let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let titleSource = generated == nil ? "prompt-fallback" : "codex"
        let latest: BoardTask
        do {
            latest = try tasks.taskModel(taskID)
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            StationAIDiagnostics.record("task.title_apply.skipped", fields: fields.merging(["reason": "task_unavailable"]) { _, new in new })
            return
        }
        guard latest.title == "Generating title…" else {
            StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "title_changed",
                "currentTitleState": StationAITaskTitleDiagnostics.state(of: latest.title),
                "titleSource": titleSource
            ])
            return
        }
        let resolvedTitle = generated.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        do {
            guard try await tasks.renameIfTitleMatches(
                taskID,
                expectedTitle: "Generating title…",
                title: resolvedTitle
            ) != nil else {
                let currentTitle = (try? tasks.taskModel(taskID).title) ?? ""
                StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                    "taskID": taskID.uuidString,
                    "reason": "title_changed",
                    "currentTitleState": StationAITaskTitleDiagnostics.state(of: currentTitle),
                    "titleSource": titleSource
                ])
                return
            }
            StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                "taskID": taskID.uuidString,
                "titleSource": titleSource,
                "fallbackWordCount": generated == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
            ])
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [resolvedTitle, prompt])
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            StationAIDiagnostics.record("task.title_apply.failed", fields: fields)
            guard generated != nil else { throw error }

            // A generated title is optional; recover with the deterministic prompt
            // fallback before any auto-named worktree can be allocated.
            do {
                guard try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: "Generating title…",
                    title: fallback
                ) != nil else {
                    let currentTitle = (try? tasks.taskModel(taskID).title) ?? ""
                    StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": taskID.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": StationAITaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": "prompt-fallback"
                    ])
                    return
                }
                StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": taskID.uuidString,
                    "titleSource": "prompt-fallback",
                    "fallbackWordCount": String(fallback.split(whereSeparator: \.isWhitespace).count)
                ])
            } catch {
                var recoveryFields = StationAIDiagnostics.errorFields(error, redacting: [fallback, prompt])
                recoveryFields["taskID"] = taskID.uuidString
                recoveryFields["titleSource"] = "prompt-fallback"
                recoveryFields["recoveryAttempt"] = "true"
                StationAIDiagnostics.record("task.title_apply.failed", fields: recoveryFields)
                throw error
            }
        }
    }

    private static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    static func isValidImageDataURL(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ",") else { return false }
        let mime = String(value[..<separator])
        guard let data = Data(base64Encoded: String(value[value.index(after: separator)...])), data.count <= 10_000_000 else { return false }
        let bytes = [UInt8](data.prefix(12))
        if mime == "data:image/png;base64" {
            return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        }
        if mime == "data:image/jpeg;base64" {
            return bytes.starts(with: [255, 216, 255])
        }
        return false
    }
}

struct BridgeCommandError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class StationAIBridgeRuntime {
    func perform(
        _ request: BridgeRequest,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async -> BridgeResponse {
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        let requestFields = Self.diagnosticRequestFields(request)
        StationAIDiagnostics.record("bridge.request.started", fields: requestFields)
        guard request.version == BridgeContract.currentVersion else {
            let response = BridgeResponse.failure(
                request,
                code: "unsupported_version",
                message: "Unsupported bridge version \(request.version). This service supports version \(BridgeContract.currentVersion)."
            )
            StationAIDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": "unsupported_version",
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await StationAIDiagnostics.endBatch()
            return response
        }

        do {
            let dataDirectory: String?
            #if DEBUG
            dataDirectory = request.dataDirectory
            #else
            dataDirectory = nil
            #endif
            let container = try StationAIStore.makeContainer(dataDirectory: dataDirectory)
            try await StationAIStore.prepareLifecycle(container: container, dataDirectory: dataDirectory)
            let context = ModelContext(container)
            let worktreeRoot: URL
            #if DEBUG
            worktreeRoot = request.worktreeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? StationAIWorktreeManager.defaultRoot()
            #else
            worktreeRoot = StationAIWorktreeManager.defaultRoot()
            #endif
            let taskManager = BoardTaskManager(modelContext: context, worktreeRoot: worktreeRoot)
            let preferences: UserDefaults
            #if DEBUG
            if let suite = request.defaultsSuite, let isolated = UserDefaults(suiteName: suite) {
                preferences = isolated
            } else {
                let applicationIdentifier = Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String
                    ?? "com.stationai.app"
                preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            }
            #else
            let applicationIdentifier = Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String
                ?? "com.stationai.app"
            preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            #endif
            let settings = WorkspaceSettingsManager(defaults: preferences)
            let workspaces = WorkspaceManager(taskManager: taskManager)

            let result: BridgeValue
            switch request.command {
            case "status":
                result = .object(["service": .string("StationAI"), "bridgeVersion": .integer(BridgeContract.currentVersion)])
            case "board.list", "task.list":
                result = try Self.value(["tasks": taskManager.list()])
            case "archive.search":
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                result = try Self.value(await conversations.searchArchive(
                    query: request.requiredString("query"),
                    codexHomePath: request.arguments["codexHome"]?.string
                ))
            case "task.create":
                let title = try request.requiredString("title")
                let roots = try request.requiredStrings("roots")
                let repositories = try request.repositorySpecs("repositories")
                result = try Self.value(await taskManager.create(title: title, repositories: repositories, contextFolders: roots))
            case "task.get", "task.show":
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(taskManager.get(taskID))
            case "task.move":
                let taskID = try request.requiredUUID("taskID")
                let status = try request.requiredString("status")
                result = try Self.value(await taskManager.move(
                    taskID,
                    to: status,
                    allowUnmergedPullRequests: request.arguments["allowUnmergedPullRequests"]?.bool ?? false
                ))
            case "task.pr.create":
                result = try Self.value(await taskManager.createPullRequests(
                    request.requiredUUID("taskID"),
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string),
                    conflictAction: settings.pullRequestConflictAction
                ))
            case "task.pr.conflicts":
                result = .object(["repositories": .array(try await taskManager.pullRequestConflictRepositories(request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "task.pr.status":
                result = try Self.value(await taskManager.reviewPullRequests(request.requiredUUID("taskID")))
            case "task.pr.verify":
                result = .object(["status": .string(try await taskManager.verifyPullRequestResolution(request.requiredUUID("taskID")).rawValue)])
            case "task.pr.resolve":
                result = try Self.value(await taskManager.resolvePullRequestConflicts(
                    request.requiredUUID("taskID"), action: request.requiredString("action"),
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                ))
            case "task.progress.publish":
                let rawType = try request.requiredString("type")
                guard let type = TaskProgressType(rawValue: rawType) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Unknown progress type '\(rawType)'. Valid types: \(TaskProgressType.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                let detail = request.arguments["detail"]?.string
                result = try Self.value(try await taskManager.publishProgressReport(request.requiredUUID("taskID"), type: type, detail: detail))
            case "task.progress.custom":
                result = try Self.value(try await taskManager.publishProgressReport(
                    request.requiredUUID("taskID"), type: nil,
                    customLabel: request.requiredString("label"),
                    detail: request.arguments["detail"]?.string
                ))
            case "task.progress.clear":
                result = try Self.value(try await taskManager.clearProgressReport(request.requiredUUID("taskID")))
            case "task.outcome":
                let taskID = try request.requiredUUID("taskID")
                let outcome = try await taskManager.reportTurnOutcome(taskID, outcome: request.requiredString("outcome"))
                result = .object([
                    "outcome": .string(outcome),
                    "taskStatus": .string(try taskManager.taskModel(taskID).status.rawValue)
                ])
            case "task.rename":
                let taskID = try request.requiredUUID("taskID")
                let title = try request.requiredString("title")
                result = try Self.value(try await taskManager.rename(taskID, title: title))
            case "task.repository.add":
                result = try Self.value(await workspaces.addRepository(
                    request.requiredString("repositoryPath"),
                    to: request.requiredUUID("taskID")
                ))
            case "task.repository.add-batch":
                result = try Self.value(await workspaces.addRepositories(
                    request.requiredStrings("repositoryPaths"),
                    to: request.requiredUUID("taskID")
                ))
            case "task.repository.edit":
                result = try Self.value(await taskManager.updateRepository(
                    request.requiredUUID("taskID"),
                    repositoryPath: request.requiredString("repositoryPath"),
                    branch: request.requiredString("branch"),
                    branchFrom: request.requiredString("branchFrom"),
                    mergeTarget: request.arguments["mergeTarget"]?.string
                ))
            case "task.repository.remove":
                result = try Self.value(await taskManager.removeRepository(
                    request.requiredUUID("taskID"),
                    repositoryPath: request.requiredString("repositoryPath")
                ))
            case "task.prompt.save":
                let status = try request.arguments["status"]?.string.map { value -> TaskStatus in
                    guard let status = TaskStatus(rawValue: value) else { throw StationAIManagerError.invalidStatus(value) }
                    return status
                }
                guard let prompt = request.arguments["prompt"]?.string else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: prompt.")
                }
                let submitted = request.arguments["submitted"]?.bool ?? false
                if submitted && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw BridgeCommandError(code: "invalid_argument", message: "A submitted prompt must contain text.")
                }
                result = try Self.value(try await taskManager.savePrompt(
                    request.requiredUUID("taskID"),
                    prompt: prompt,
                    status: status,
                    submitted: submitted,
                    imageDataURLs: request.arguments["images"]?.strings
                ))
            case "task.delete":
                try await taskManager.delete(request.requiredUUID("taskID"))
                result = .object(["deleted": .boolean(true)])
            case "task.delete.requires-confirmation":
                let requiresConfirmation = try await taskManager.deleteRequiresConfirmation(request.requiredUUID("taskID"))
                result = .object(["requiresConfirmation": .boolean(requiresConfirmation)])
            case "task.roots.get", "workspace.roots":
                result = .object(["roots": .array(try workspaces.roots(for: request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "task.roots.set":
                let roots = try request.requiredStrings("roots")
                result = try Self.value(await workspaces.setRoots(roots, for: request.requiredUUID("taskID")))
            case "task.changes.list":
                result = try Self.value(await workspaces.changes(for: request.requiredUUID("taskID")))
            case "task.changes.diff":
                result = try Self.value(await workspaces.diff(
                    for: request.requiredUUID("taskID"),
                    repository: request.requiredString("repository"),
                    path: request.requiredString("path"),
                    group: request.requiredString("group")
                ))
            case "workspace.suggest":
                let parent = try request.requiredString("parent")
                result = .object(["repositories": .array(try await workspaces.suggestedRepositories(parentPath: parent).map(BridgeValue.string))])
            case "settings.get":
                result = .object([
                    "defaultParentFolder": settings.defaultParentFolderPath.isEmpty ? .null : .string(settings.defaultParentFolderPath),
                    "defaultParentAvailable": .boolean(settings.defaultParentFolderURL != nil),
                    "lastSelectedRepositories": .array(settings.lastSelectedRepositories.map(BridgeValue.string)),
                    "appearance": .string(settings.appearance),
                    "pullRequestConflictAction": .string(settings.pullRequestConflictAction)
                ])
            case "settings.set-pr-conflict-action":
                try settings.setPullRequestConflictAction(request.requiredString("action"))
                result = .object(["pullRequestConflictAction": .string(settings.pullRequestConflictAction)])
            case "settings.set-appearance":
                try settings.setAppearance(request.requiredString("appearance"))
                result = .object(["appearance": .string(settings.appearance)])
            case "settings.set-parent":
                try settings.setDefaultParentFolder(request.requiredString("path"))
                result = .object(["defaultParentFolder": .string(settings.defaultParentFolderPath)])
            case "settings.clear-parent":
                try settings.setDefaultParentFolder(nil)
                result = .object(["defaultParentFolder": .null])
            case "settings.set-last-repositories":
                let repositories = try request.requiredStrings("repositories")
                try settings.setLastSelectedRepositories(repositories)
                result = .object(["lastSelectedRepositories": .array(settings.lastSelectedRepositories.map(BridgeValue.string))])
            case "conversation.history":
                let taskID = try request.requiredUUID("taskID")
                let codexClient = CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                _ = try await taskManager.reconcileLifecycleStatusOnOpen(taskID, client: codexClient)
                let conversations = CodexConversationManager(
                    tasks: taskManager,
                    client: codexClient
                )
                result = try Self.value(await conversations.history(taskID: taskID))
            case "conversation.models":
                let codexClient = CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                let conversations = CodexConversationManager(tasks: taskManager, client: codexClient)
                result = .object(["models": .array(try await conversations.models(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.queue", "conversation.queue.list", "conversation.queue.retry", "conversation.queue.remove", "conversation.queue.steer", "conversation.steer":
                let taskID = try request.requiredUUID("taskID")
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string))
                switch request.command {
                case "conversation.queue": result = try Self.value(conversations.queueMessage(taskID: taskID, text: request.requiredString("message")))
                case "conversation.queue.list": result = .array(try conversations.queuedMessages(taskID: taskID).map { try Self.value($0) })
                case "conversation.queue.retry":
                    let retried = try await conversations.retryQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"))
                    result = .object(["retried": .boolean(retried)])
                case "conversation.queue.remove":
                    try conversations.removeQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"))
                    result = .object(["removed": .boolean(true)])
                case "conversation.queue.steer":
                    let steered = try await conversations.steerQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"))
                    result = .object(["text": .string(steered.message), "accepted": .boolean(true), "queued": .boolean(!steered.accepted)])
                default:
                    let accepted = try await conversations.steer(taskID: taskID, text: request.arguments["message"]?.string ?? "", imageDataURLs: request.arguments["images"]?.strings ?? [])
                    if accepted {
                        result = .object(["accepted": .boolean(true), "queued": .boolean(false)])
                    } else {
                        _ = try await conversations.queueMissedSteer(taskID: taskID, text: request.arguments["message"]?.string ?? "", imageDataURLs: request.arguments["images"]?.strings ?? [])
                        result = .object(["accepted": .boolean(true), "queued": .boolean(true)])
                    }
                }
            case "conversation.send":
                let taskID = try request.requiredUUID("taskID")
                let message = request.arguments["message"]?.string ?? ""
                let modeValue = request.arguments["mode"]?.string ?? CodexConversationMode.code.rawValue
                guard let mode = CodexConversationMode(rawValue: modeValue) else {
                    throw BridgeCommandError(
                        code: "invalid_argument",
                        message: "Unknown conversation mode '\(modeValue)'. Valid modes: default, plan."
                    )
                }
                let modelID = request.arguments["model"]?.string ?? CodexAppServerClient.modelID
                let answers = try request.optionalStringArrays("answers")
                let imageDataURLs = request.arguments["images"]?.strings ?? []
                let conversations = CodexConversationManager(
                    tasks: taskManager,
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                )
                let history = try await conversations.send(taskID: taskID, text: message, imageDataURLs: imageDataURLs, mode: mode, modelID: modelID, userInputAnswers: answers, onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                })
                result = try Self.value(history)
            default:
                throw BridgeCommandError(code: "unknown_command", message: "Unknown command '\(request.command)'. Run 'stationai help' to list commands.")
            }
            let response = BridgeResponse.success(request, result: result)
            StationAIDiagnostics.record("bridge.request.succeeded", fields: requestFields.merging(
                Self.diagnosticResultFields(result).merging([
                    "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
                ]) { _, new in new }
            ) { _, new in new })
            await StationAIDiagnostics.endBatch()
            return response
        } catch let error as BridgeCommandError {
            StationAIDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": error.code,
                "errorDescription": error.message,
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await StationAIDiagnostics.endBatch()
            return .failure(request, code: error.code, message: error.message)
        } catch let error as StationAIManagerError {
            let code: String
            switch error {
            case .taskNotFound: code = "not_found"
            case .invalidTitle, .invalidStatus, .noWorkspaceRoots, .unavailableWorkspaceRoot, .invalidParentFolder, .invalidMessage, .repositoryAssigned: code = "invalid_argument"
            case .invalidTransition: code = "invalid_argument"
            case .unmergedPullRequests: code = "invalid_transition"
            }
            StationAIDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": code,
                "errorDescription": error.localizedDescription,
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await StationAIDiagnostics.endBatch()
            return .failure(request, code: code, message: error.localizedDescription)
        } catch {
            var fields = requestFields
            fields.merge(StationAIDiagnostics.errorFields(error)) { _, new in new }
            fields["errorCode"] = "operation_failed"
            fields["durationMilliseconds"] = Self.elapsedMilliseconds(since: requestStartedAt)
            StationAIDiagnostics.record("bridge.request.failed", fields: fields)
            await StationAIDiagnostics.endBatch()
            return .failure(request, code: "operation_failed", message: error.localizedDescription)
        }
    }

    private static func diagnosticRequestFields(_ request: BridgeRequest) -> [String: String] {
        var fields = [
            "requestID": request.id,
            "command": request.command,
            "argumentCount": String(request.arguments.count),
            "argumentNames": request.arguments.keys.sorted().joined(separator: ",")
        ]
        for (key, value) in request.arguments {
            let normalizedKey = key.lowercased()
            if normalizedKey == "images", case .array(let values) = value {
                fields["argument.\(key).provided"] = "true"
                fields["argument.\(key).itemCount"] = String(values.count)
                for (index, value) in values.enumerated() {
                    guard case .string(let dataURL) = value,
                          dataURL.hasPrefix("data:image/"),
                          let separator = dataURL.firstIndex(of: ",") else { continue }
                    let metadata = dataURL[..<separator]
                    let mime = metadata.dropFirst("data:".count).split(separator: ";", maxSplits: 1).first.map(String.init) ?? "unknown"
                    fields["argument.\(key).\(index).mime"] = mime
                    fields["argument.\(key).\(index).encodedCharacterCount"] = String(dataURL[dataURL.index(after: separator)...].count)
                }
                continue
            }
            if ["message", "text", "prompt", "body", "summary", "answers", "images", "content"].contains(normalizedKey) {
                fields["argument.\(key).provided"] = "true"
                switch value {
                case .string(let text): fields["argument.\(key).utf8Bytes"] = String(text.utf8.count)
                case .array(let values): fields["argument.\(key).itemCount"] = String(values.count)
                case .object(let values): fields["argument.\(key).itemCount"] = String(values.count)
                default: break
                }
                continue
            }
            switch value {
            case .string(let string):
                fields["argument.\(key)"] = string
            case .integer(let number):
                fields["argument.\(key)"] = String(number)
            case .decimal(let number):
                fields["argument.\(key)"] = String(number)
            case .boolean(let boolean):
                fields["argument.\(key)"] = String(boolean)
            case .array(let values):
                fields["argument.\(key).itemCount"] = String(values.count)
                let strings = values.compactMap(\.string)
                if strings.count == values.count {
                    fields["argument.\(key).values"] = strings.joined(separator: "\n")
                }
                for (index, item) in values.enumerated() {
                    guard case .object(let itemFields) = item else { continue }
                    fields["argument.\(key).\(index).fieldNames"] = itemFields.keys.sorted().joined(separator: ",")
                    for (itemKey, itemValue) in itemFields {
                        let itemField = "argument.\(key).\(index).\(itemKey)"
                        let normalizedItemKey = itemKey.lowercased()
                        if ["message", "text", "prompt", "body", "summary", "answers", "images", "content"].contains(normalizedItemKey) {
                            fields["\(itemField).provided"] = "true"
                            continue
                        }
                        switch itemValue {
                        case .string(let string): fields[itemField] = string
                        case .integer(let number): fields[itemField] = String(number)
                        case .decimal(let number): fields[itemField] = String(number)
                        case .boolean(let boolean): fields[itemField] = String(boolean)
                        case .array(let nested): fields["\(itemField).itemCount"] = String(nested.count)
                        case .object(let nested): fields["\(itemField).itemCount"] = String(nested.count)
                        case .null: fields["\(itemField).isNull"] = "true"
                        }
                    }
                }
            case .object(let values):
                fields["argument.\(key).itemCount"] = String(values.count)
                fields["argument.\(key).subkeys"] = values.keys.sorted().joined(separator: "\n")
            case .null:
                fields["argument.\(key).isNull"] = "true"
            }
        }
        if let dataDirectory = request.dataDirectory { fields["dataDirectory"] = dataDirectory }
        if let worktreeDirectory = request.worktreeDirectory { fields["worktreeDirectory"] = worktreeDirectory }
        return fields
    }

    private static func diagnosticResultFields(_ result: BridgeValue) -> [String: String] {
        switch result {
        case .object(let values):
            var fields = ["resultKind": "object", "resultFieldCount": String(values.count)]
            for key in ["id", "status", "taskStatus", "command", "count"] {
                if let value = values[key]?.string { fields["result.\(key)"] = value }
                else if let value = values[key] {
                    switch value {
                    case .integer(let number): fields["result.\(key)"] = String(number)
                    case .boolean(let boolean): fields["result.\(key)"] = String(boolean)
                    default: break
                    }
                }
            }
            return fields
        case .array(let values):
            return ["resultKind": "array", "resultItemCount": String(values.count)]
        case .string(let value):
            return ["resultKind": "string", "resultUTF8Bytes": String(value.utf8.count)]
        case .integer, .decimal, .boolean:
            return ["resultKind": "scalar"]
        case .null:
            return ["resultKind": "null"]
        }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> String {
        String((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private static func value<T: Encodable>(_ value: T) throws -> BridgeValue {
        let data = try JSONEncoder.bridge.encode(value)
        return try JSONDecoder().decode(BridgeValue.self, from: data)
    }

}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension BridgeRequest {
    func requiredString(_ name: String) throws -> String {
        guard let value = arguments[name]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: \(name).")
        }
        return value
    }

    func requiredStrings(_ name: String) throws -> [String] {
        guard let value = arguments[name]?.strings else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required list argument: \(name).")
        }
        return value
    }

    func requiredStringArrays(_ name: String) throws -> [String: [String]] {
        guard let object = arguments[name]?.object else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required answer map: \(name).")
        }
        var result: [String: [String]] = [:]
        for (key, value) in object {
            guard case .array(let values) = value else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            let strings = values.compactMap(\.string)
            guard strings.count == values.count else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            result[key] = strings
        }
        return result
    }

    func optionalStringArrays(_ name: String) throws -> [String: [String]] {
        guard arguments[name] != nil else { return [:] }
        return try requiredStringArrays(name)
    }

    func repositorySpecs(_ name: String) throws -> [RepositoryWorktreeSpec] {
        guard case .array(let values)? = arguments[name] else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing repository list argument: \(name).")
        }
        return try values.map { value in
            guard let object = value.object, let path = object["repositoryPath"]?.string else {
                throw BridgeCommandError(code: "invalid_argument", message: "Each repository must include a repositoryPath.")
            }
            return RepositoryWorktreeSpec(
                repositoryPath: path,
                branch: object["branch"]?.string,
                branchFrom: object["branchFrom"]?.string,
                mergeTarget: object["mergeTarget"]?.string
            )
        }
    }

    func requiredUUID(_ name: String) throws -> UUID {
        guard let rawValue = arguments[name]?.string, let id = UUID(uuidString: rawValue) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be a task UUID.")
        }
        return id
    }
}

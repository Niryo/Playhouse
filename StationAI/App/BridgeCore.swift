import Foundation
import SwiftData
import Darwin
import SQLite3

enum CodexGoalGenerationStore {
    static func generationIDKey(taskID: UUID) -> String {
        "stationai.codex.goal-generation.\(taskID.uuidString)"
    }

    static func objectiveKey(taskID: UUID) -> String {
        "stationai.codex.goal-generation-objective.\(taskID.uuidString)"
    }

    static func timeBaselineKey(taskID: UUID) -> String {
        "stationai.codex.goal-generation-time-baseline.\(taskID.uuidString)"
    }

    private static func clearedTimeCarryoverKey(taskID: UUID) -> String {
        "stationai.codex.goal-cleared-time-carryover.\(taskID.uuidString)"
    }

    static func recordClear(taskID: UUID, goal: CodexThreadGoal?, defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        guard let goal else { return }
        defaults.set(Double(goal.timeUsedSeconds ?? 0), forKey: clearedTimeCarryoverKey(taskID: taskID))
    }

    static func recordSet(taskID: UUID, objective: String, previousGoal: CodexThreadGoal?, goal: CodexThreadGoal, defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        let startsNewGeneration = previousGoal == nil
            || previousGoal?.status == "complete"
            || previousGoal?.objective != objective
        guard startsNewGeneration else { return }
        let previousTimeTotal: Double?
        if let previousGoal {
            previousTimeTotal = Double(previousGoal.timeUsedSeconds ?? 0)
        } else {
            previousTimeTotal = defaults.object(forKey: clearedTimeCarryoverKey(taskID: taskID)) as? Double
        }
        let reportedSeconds = Double(goal.timeUsedSeconds ?? 0)
        let timeBaseline = previousTimeTotal.map { reportedSeconds >= $0 ? $0 : 0 } ?? 0
        defaults.set(UUID().uuidString, forKey: generationIDKey(taskID: taskID))
        defaults.set(goal.objective, forKey: objectiveKey(taskID: taskID))
        defaults.set(timeBaseline, forKey: timeBaselineKey(taskID: taskID))
        defaults.removeObject(forKey: clearedTimeCarryoverKey(taskID: taskID))
    }
}

/// Generates a short task title with a one-shot helper turn. Clients are tried
/// in order, moving to the next only when a provider is unavailable (not
/// installed, can't start, or not signed in), so a working provider's empty
/// answer still falls back to the prompt rather than to another model.
@MainActor
struct ConversationTitleGenerator {
    let clients: [ConversationProviderClient]

    func generateTitle(from prompt: String, workspace: ConversationWorkspaceContext, taskID: UUID) async -> (title: String, provider: ConversationProvider)? {
        for client in clients {
            switch await attempt(client, prompt: prompt, workspace: workspace, taskID: taskID) {
            case .generated(let title): return (title, client.provider)
            case .unavailable: continue
            case .failed: return nil
            }
        }
        return nil
    }

    private enum Attempt {
        case generated(String)
        case unavailable
        case failed
    }

    private func attempt(_ client: ConversationProviderClient, prompt: String, workspace: ConversationWorkspaceContext, taskID: UUID) async -> Attempt {
        var phase = "thread-start"
        var threadID = ""
        do {
            threadID = try await client.startThread(workspace: workspace, modelID: client.provider.titleModelID, developerInstructions: nil)
            StationAIDiagnostics.record("task.title_generation.started", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "modelID": client.provider.titleModelID,
                "provider": client.provider.rawValue
            ])
            var generated: String?
            phase = "title-turn"
            try await client.sendMessage(
                "Write a concise task title of at most 8 words for this request. Return only the title:\n\n\(prompt)",
                mode: .plan,
                modelID: client.provider.titleModelID,
                threadID: threadID,
                workspace: workspace,
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
            guard let title = generated?.components(separatedBy: .newlines).first,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                StationAIDiagnostics.record("task.title_generation.failed", fields: [
                    "taskID": taskID.uuidString,
                    "threadID": threadID,
                    "phase": phase,
                    "provider": client.provider.rawValue,
                    "reason": "empty_response"
                ])
                return .failed
            }
            StationAIDiagnostics.record("task.title_generation.succeeded", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "phase": phase,
                "provider": client.provider.rawValue,
                "titleWordCount": String(title.split(whereSeparator: \.isWhitespace).count)
            ])
            return .generated(title)
        } catch {
            let unavailable = client.isProviderUnavailable(error)
            var fields = StationAIDiagnostics.errorFields(error, redacting: [prompt])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["phase"] = phase
            fields["provider"] = client.provider.rawValue
            fields["providerUnavailable"] = String(unavailable)
            StationAIDiagnostics.record("task.title_generation.failed", fields: fields)
            return unavailable ? .unavailable : .failed
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
                   t0.ZVIEWEDWORKSPACECHANGESDATA,
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
    let claudeSessionID: String?
    let conversationProvider: String
    let conversationEffort: String
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
        claudeSessionID = task.claudeSessionID
        conversationProvider = task.conversationProvider.rawValue
        conversationEffort = task.conversationEffort
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
    var asyncQuestionItemID: String? = nil
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
        let paths = (StationAIProcessEnvironment.current["PATH"] ?? "").split(separator: ":").map {
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
        // A quarantined test fixture script runs through its interpreter.
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        do {
            result = try StationAIProcessRunner.run(
                executable: command.executable,
                arguments: command.arguments,
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

    func enqueueConversationMessage(taskID: UUID, text: String, imageDataURLs: [String] = [], asyncQuestionItemID: String? = nil) throws -> QueuedConversationMessage {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        let task = try taskModel(taskID)
        guard let threadID = task.activeConversationID else {
            throw BridgeCommandError(code: "invalid_transition", message: "A follow-up can only be queued after this conversation has a \(task.conversationProvider.displayName) conversation.")
        }
        let item = QueuedConversationMessage(
            id: UUID(), taskID: taskID, threadID: threadID, text: normalized, imageDataURLs: imageDataURLs, state: .queued,
            enqueuedProcessID: nil, asyncQuestionItemID: asyncQuestionItemID
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

    func conversationTranscriptStore() throws -> ConversationTranscriptStore {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for conversation transcripts.")
        }
        return ConversationTranscriptStore(directory: storeURL.deletingLastPathComponent().appendingPathComponent("conversation-transcripts", isDirectory: true))
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

    fileprivate func withTaskOperationLock<T>(
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
        let lockURL = conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try hasReservation(at: lockURL, purpose: "conversation-turn")
    }

    private func hasReservation(at url: URL, purpose: String) throws -> Bool {
        let lockURL = url.standardizedFileURL
        let key = lockURL.path
        guard !TaskOperationLockGate.isHeld(key) else { return true }

        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw BridgeFileLockError(message: "Couldn't inspect the \(purpose) reservation (errno \(errno)).")
        }
        defer { _ = Darwin.close(descriptor) }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_GETLK, &lock) == 0 else {
            throw BridgeFileLockError(message: "Couldn't inspect the \(purpose) reservation (errno \(errno)).")
        }
        return lock.l_type != Int16(F_UNLCK)
    }

    fileprivate func queueDeferredRepositoryRemoval(taskID: UUID, record: RepositoryWorktreeRecord) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for deferred repository cleanup.")
        }
        try FileManager.default.createDirectory(at: conversationTurnLockDirectory, withIntermediateDirectories: true)
        let payload = DeferredRepositoryRemoval(taskID: taskID, record: record)
        let url = conversationTurnLockDirectory.appendingPathComponent("\(taskID.uuidString).\(UUID().uuidString).repository-removal.json")
        try JSONEncoder().encode(payload).write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return url
    }

    fileprivate func deferredRepositoryRemovals() throws -> [(URL, DeferredRepositoryRemoval)] {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for deferred repository cleanup.")
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: conversationTurnLockDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return try urls.filter { $0.lastPathComponent.hasSuffix(".repository-removal.json") }.compactMap { url in
            (url, try JSONDecoder().decode(DeferredRepositoryRemoval.self, from: Data(contentsOf: url)))
        }
    }

    fileprivate func clearDeferredRepositoryRemoval(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
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
    func create(title: String, workspaceRoots: [String], provider: ConversationProvider = .codex) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let normalizedRoots = try Self.normalizeRoots(workspaceRoots)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: normalizedRoots, conversationProvider: provider)
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
    func create(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [String], provider: ConversationProvider = .codex) async throws -> BoardTaskRecord {
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
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: roots, conversationProvider: provider)
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
                "status": task.status.rawValue,
                "provider": provider.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func addRepository(
        _ id: UUID,
        repositoryPath: String,
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        return try await addRepositories(
            id,
            repositoryPaths: [repositoryPath],
            duringActiveConversation: duringActiveConversation
        )
    }

    @discardableResult
    func addRepositories(
        _ id: UUID,
        repositoryPaths: [String],
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
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

        let mutation = {
            try await self.withTaskOperationLock(id) {
                return try await self.withRepositoryAllocationLocks(records.map(\.repositoryPath)) {
                    let task = try self.requireTask(id)
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
                    try self.validateRepositoryAssignments(records, excludingTaskID: id)

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
                    try await self.saveTaskContext(taskID: id)
                    StationAIDiagnostics.record("workspace.repository.add.succeeded", fields: [
                        "taskID": id.uuidString,
                        "repositoryCount": String(records.count),
                        "repositoryPaths": records.map(\.repositoryPath).joined(separator: "\n")
                    ])
                    return BoardTaskRecord(task: task)
                }
            }
        }
        if duringActiveConversation {
            return try await mutation()
        }
        return try await withConversationTurnReservation(id) {
            try await mutation()
        }
    }

    @discardableResult
    func replaceRepositories(
        _ id: UUID,
        repositoryPaths: [String],
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        guard !repositoryPaths.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Replace with at least one repository.")
        }
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }

        var seen = Set<String>()
        var normalizedPaths: [String] = []
        for path in repositoryPaths {
            let record = try await worktreeService.pendingRecord(
                spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
            )
            let canonical = Self.canonicalPath(record.repositoryPath)
            guard seen.insert(canonical).inserted else {
                throw BridgeCommandError(code: "invalid_argument", message: "A repository can be selected only once per task: \(record.repositoryPath)")
            }
            normalizedPaths.append(record.repositoryPath)
        }

        let desired = Set(normalizedPaths.map(Self.canonicalPath))
        let existing = Set(initialTask.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
        let additions = normalizedPaths.filter { !existing.contains(Self.canonicalPath($0)) }
        if !additions.isEmpty {
            _ = try await addRepositories(
                id,
                repositoryPaths: additions,
                duringActiveConversation: duringActiveConversation
            )
        }

        let latestTask = try requireTask(id)
        let removals = latestTask.repositoryWorktrees
            .filter { !desired.contains(Self.canonicalPath($0.repositoryPath)) }
            .map(\.repositoryPath)
        for path in removals {
            do {
                _ = try await removeRepository(
                    id,
                    repositoryPath: path,
                    duringActiveConversation: duringActiveConversation
                )
            } catch {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "The replacement repositories were added, but the old repository \(path) couldn't be removed. The task keeps both contexts. \(error.localizedDescription)"
                )
            }
        }
        return try get(id)
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
    func removeRepository(
        _ id: UUID,
        repositoryPath: String,
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        if duringActiveConversation {
            return try await removeRepositoryWhileTurnReserved(
                id,
                repositoryPath: repositoryPath,
                deferWorktreeRemovalUntilTurnEnds: true
            )
        }
        return try await withConversationTurnReservation(id) {
            try await self.removeRepositoryWhileTurnReserved(id, repositoryPath: repositoryPath)
        }
    }

    private func removeRepositoryWhileTurnReserved(
        _ id: UUID,
        repositoryPath: String,
        deferWorktreeRemovalUntilTurnEnds: Bool = false
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
            // A task with no repository roots is a valid standalone conversation.
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

                let deferredIntentURL = shouldRemoveWorktree && deferWorktreeRemovalUntilTurnEnds
                    ? try queueDeferredRepositoryRemoval(taskID: id, record: record)
                    : nil

                currentTask.repositoryWorktrees = updatedRepositories
                currentTask.workspaceRootPaths = roots
                do {
                    try await saveTaskContext(taskID: id)
                } catch {
                    currentTask.repositoryWorktrees = originalRepositories
                    currentTask.workspaceRootPaths = originalRoots
                    throw error
                }

                if shouldRemoveWorktree {
                    if deferWorktreeRemovalUntilTurnEnds {
                        StationAIDiagnostics.record("workspace.repository.deferred_removal_scheduled", fields: [
                            "taskID": id.uuidString,
                            "repositoryPath": record.repositoryPath,
                            "worktreePath": record.worktreePath
                        ])
                        // Runs after this request returns, once the task's turn ends; keep
                        // this request's environment and diagnostics routing for it.
                        let requestContext = StationAIRequestContext.capture()
                        Task.detached { @MainActor in
                            await requestContext.run {
                                do {
                                    StationAIDiagnostics.record("workspace.repository.deferred_removal_waiting", fields: [
                                        "taskID": id.uuidString,
                                        "repositoryPath": record.repositoryPath,
                                        "worktreePath": record.worktreePath
                                    ])
                                    try await self.withConversationTurnReservation(id) {
                                        try await self.withTaskOperationLock(id) {
                                            guard let deferredIntentURL,
                                                  FileManager.default.fileExists(atPath: deferredIntentURL.path) else { return }
                                            if try self.isRepositoryAttached(record, to: id) {
                                                try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                                                return
                                            }
                                            StationAIDiagnostics.record("workspace.repository.deferred_removal_reservation_acquired", fields: [
                                                "taskID": id.uuidString,
                                                "repositoryPath": record.repositoryPath,
                                                "worktreePath": record.worktreePath
                                            ])
                                            if try await self.worktreeService.hasChanges(record) {
                                                StationAIDiagnostics.record("workspace.repository.deferred_removal_kept_dirty", fields: [
                                                    "taskID": id.uuidString,
                                                    "repositoryPath": record.repositoryPath,
                                                    "worktreePath": record.worktreePath
                                                ])
                                                try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                                                return
                                            }
                                            try await self.worktreeService.remove(record)
                                            StationAIDiagnostics.record("workspace.repository.deferred_removal_succeeded", fields: [
                                                "taskID": id.uuidString,
                                                "repositoryPath": record.repositoryPath,
                                                "worktreePath": record.worktreePath
                                            ])
                                            try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                                        }
                                    }
                                } catch {
                                    StationAIDiagnostics.record("workspace.repository.deferred_removal_failed", fields: [
                                        "taskID": id.uuidString,
                                        "repositoryPath": record.repositoryPath,
                                        "worktreePath": record.worktreePath,
                                        "error": error.localizedDescription
                                    ])
                                }
                            }
                        }
                    } else {
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
                }
                return try get(id)
            }
        }
    }

    @discardableResult
    func move(
        _ id: UUID,
        to statusName: String,
        allowUnmergedPullRequests: Bool = false,
        skipMergeVerification: Bool = false
    ) async throws -> BoardTaskRecord {
        StationAIDiagnostics.record("task.move.started", fields: [
            "taskID": id.uuidString,
            "requestedStatus": statusName,
            "allowUnmergedPullRequests": String(allowUnmergedPullRequests),
            "skipMergeVerification": String(skipMergeVerification)
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
            if !linkedRecords.isEmpty && !allowUnmergedPullRequests && !skipMergeVerification {
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

    func createPullRequests(_ id: UUID, clients: ConversationClients, settingsManager: WorkspaceSettingsManager? = nil) async throws -> BoardTaskRecord {
        let conflicts = try await pullRequestConflictRepositories(id)
        if !conflicts.isEmpty {
            throw BridgeCommandError(code: "conflicts_require_confirmation", message: "Pull request conflicts were found. Resolve conflicts in the task worktree before creating pull requests.")
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

        let conversation = try await ConversationManager(tasks: self, clients: clients, settingsManager: settingsManager).history(taskID: id)
        let helperClients = clients.helperClients(preferring: try requireTask(id).conversationProvider)
        let conversationText = conversation.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let currentTitle = try requireTask(id).title
        let summary: String
        if !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let roots = records.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) }
            let workspace = try ConversationWorkspaceContext(roots: roots)
            var generated = ""
            var summaryProvider = helperClients[0].provider
            // Fall back to the other provider only when the task's provider can't run here.
            for (index, client) in helperClients.enumerated() {
                summaryProvider = client.provider
                do {
                    let summaryThread = try await client.startThread(workspace: workspace, modelID: client.provider.defaultModelID, developerInstructions: nil)
                    try await client.sendMessage(
                        "Write a very concise GitHub pull request description. Explain what problem this change solves, how it solves it, and briefly mention any special issue or caveat from the conversation. Use Markdown, no more than three short sections, and return only the description.\n\nTask: \(currentTitle)\n\nConversation:\n\(conversationText)",
                        mode: .plan,
                        modelID: client.provider.defaultModelID,
                        threadID: summaryThread,
                        workspace: workspace,
                        onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    )
                    break
                } catch where client.isProviderUnavailable(error) && index < helperClients.count - 1 {
                    continue
                }
            }
            guard !generated.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "\(summaryProvider.displayName) returned an empty pull request summary. Try again.")
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
        return try await reviewPullRequests(task)
    }

    func reviewPullRequests(_ task: BoardTask) async throws -> [PullRequestReviewState] {
        let records = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil }
        return try await reviewPullRequests(records)
    }

    func reviewPullRequests(_ records: [RepositoryWorktreeRecord]) async throws -> [PullRequestReviewState] {
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

    func resolvePullRequestConflicts(_ id: UUID, action: String, clients: ConversationClients) async throws -> BoardTaskRecord {
        guard ["resolve-and-push", "resolve-only", "keep"].contains(action) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose resolve-and-push, resolve-only, or keep.")
        }
        if action == "keep" { return try get(id) }
        return try await withTaskOperationLock(id) {
            let records = try requireTask(id).repositoryWorktrees.filter { !$0.isPending && $0.pullRequestNumber == nil }
            let conflicted = try await pullRequestConflictRepositoriesUnlocked(id)
            guard !conflicted.isEmpty else { return try get(id) }
            let affected = records.filter { conflicted.contains($0.repositoryPath) }
            let roots = try ConversationWorkspaceContext(roots: affected.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) })
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
                let client = clients.client(for: try requireTask(id).conversationProvider)
                let thread = try await client.startThread(workspace: roots, modelID: client.provider.defaultModelID, developerInstructions: nil)
                do {
                    try await client.sendMessage(
                        "Resolve every Git merge conflict in the current workspace. Preserve the intended changes from both sides, inspect the resulting files, and stage the resolved files. Do not commit or push. Report which conflicts you resolved.",
                        mode: .code,
                        modelID: client.provider.defaultModelID,
                        threadID: thread,
                        workspace: roots,
                        onFinalMessage: { finalMessage = $0 },
                        onUserInput: { request in
                            client.rejectUserInput(
                                requestID: request.id,
                                threadID: request.threadID,
                                message: "Conflict resolution cannot continue while \(client.provider.displayName) is waiting for user input."
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
            task.lifecycleRevision += 1
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

    func transitionLifecycleStatus(_ id: UUID, from expectedStatus: TaskStatus, to status: TaskStatus) async throws -> Int? {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == expectedStatus, task.status != .done else { return nil }
            task.status = status
            task.statusMessage = nil
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return task.lifecycleRevision
        }
    }

    func restoreLifecycleStatus(_ id: UUID, to status: TaskStatus, ifRevision revision: Int) async throws -> Bool {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .waitingResponse, task.lifecycleRevision == revision else { return false }
            task.status = status
            task.statusMessage = nil
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return true
        }
    }

    func resumeWaitingResponseAfterUserInput(_ id: UUID) async throws -> BoardTaskRecord {
        let activeTurnURL = try conversationTurnActiveURL(id)
        StationAIDiagnostics.record("task.lifecycle_status.user_input_resume.started", fields: ["taskID": id.uuidString])
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .waitingResponse,
                  FileManager.default.fileExists(atPath: activeTurnURL.path) else {
                StationAIDiagnostics.record("task.lifecycle_status.user_input_resume.skipped", fields: [
                    "taskID": id.uuidString,
                    "reason": FileManager.default.fileExists(atPath: activeTurnURL.path) ? "status_not_waiting_response" : "turn_outcome_inactive",
                ])
                return BoardTaskRecord(task: task)
            }
            task.status = .inProgress
            task.statusMessage = nil
            try await saveTaskContext(taskID: id)
            StationAIDiagnostics.record("task.lifecycle_status.user_input_resumed", fields: [
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

    func answeredAsyncQuestionIDs(taskID: UUID) throws -> [String] {
        try requireTask(taskID).answeredAsyncQuestionIDs
    }

    func recordAnsweredAsyncQuestion(taskID: UUID, itemID: String) async throws {
        try await withTaskOperationLock(taskID) {
            let task = try self.requireTask(taskID)
            if !task.answeredAsyncQuestionIDs.contains(itemID) {
                task.answeredAsyncQuestionIDs.append(itemID)
                try await self.saveTaskContext(taskID: taskID)
            }
        }
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

    func reconcileLifecycleStatusOnOpen(_ id: UUID, clients: ConversationClients) async throws -> BoardTaskRecord {
        let currentTask = try requireTask(id)
        guard currentTask.activeConversationID != nil || currentTask.pendingSubmittedPrompt != nil else {
            return BoardTaskRecord(task: currentTask)
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            let providerName = task.conversationProvider.displayName
            let client = clients.client(for: task.conversationProvider)
            guard let threadID = task.activeConversationID else {
                if task.pendingSubmittedPrompt != nil, !(try hasConversationTurnReservation(id)) {
                    if task.status == .inProgress {
                        task.status = .waitingResponse
                        task.statusMessage = "StationAI restarted before \(providerName) started this turn. Your prompt is saved; review it and continue when ready."
                    }
                    task.pendingSubmittedPrompt = nil
                    try await saveTaskContext(taskID: id)
                }
                return BoardTaskRecord(task: task)
            }
            let hasActiveReservation = try hasConversationTurnReservation(id)
            guard !client.isTurnActive(threadID: threadID),
                  !client.isTurnActiveInProcess(threadID: threadID),
                  !hasActiveReservation else {
                return BoardTaskRecord(task: task)
            }
            let pendingQuestion = try conversationTranscriptStore().read(id).pendingUserInputRequest
            if let pendingQuestion, pendingQuestion.threadID == threadID, task.status != .done {
                let pendingStatus: TaskStatus = pendingQuestion.isBlocking ? .waitingResponse : .inProgress
                let pendingStatusMessage = pendingQuestion.isBlocking
                    ? "Waiting for your saved question to be answered."
                    : "A saved question is available for your response."
                if task.status != pendingStatus || task.statusMessage != pendingStatusMessage {
                    task.status = pendingStatus
                    task.statusMessage = pendingStatusMessage
                    clearProgressReport(task)
                    try await saveTaskContext(taskID: id)
                }
                return BoardTaskRecord(task: task)
            }
            // A turn the user paused is waiting on purpose; it needs no restart notice.
            if task.status == .waitingResponse, client.wasLastTurnInterrupted(threadID: threadID) {
                return BoardTaskRecord(task: task)
            }
            let message: String
            switch task.status {
            case .inProgress:
                message = "StationAI closed while this turn was running. Your conversation is saved; review it and send a follow-up to continue."
            default:
                // Waiting Response without a saved question is a finished turn waiting for the user.
                return BoardTaskRecord(task: task)
            }
            task.status = .waitingResponse
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
        if let imageDataURLs, imageDataURLs.count > 8 || imageDataURLs.contains(where: { !ConversationManager.isValidImageDataURL($0) }) {
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

    func persistConversationID(_ id: UUID, provider: ConversationProvider, id conversationID: String) async throws -> BoardTaskRecord {
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(provider.displayName) returned an empty conversation ID.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            let existing = task.conversationID(for: provider)
            guard existing == nil || existing == conversationID else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task is already linked to a different \(provider.displayName) conversation.")
            }
            guard existing != conversationID else { return BoardTaskRecord(task: task) }
            switch provider {
            case .codex: task.codexThreadID = conversationID
            case .claude: task.claudeSessionID = conversationID
            }
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                switch provider {
                case .codex: task.codexThreadID = nil
                case .claude: task.claudeSessionID = nil
                }
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    /// Persists which provider runs the task's next turn. Callers that already
    /// have a conversation go through `ConversationManager.setProvider`, which
    /// checks that the conversation is settled and records the boundary.
    func setConversationProvider(_ id: UUID, provider: ConversationProvider) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.conversationProvider != provider || task.conversationProviderRawValue == nil else { return BoardTaskRecord(task: task) }
            let previous = task.conversationProviderRawValue
            task.conversationProvider = provider
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationProviderRawValue = previous
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    func setConversationEffort(_ id: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            let previous = task.conversationEffortRawValue
            task.conversationEffort = effort.rawValue
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationEffortRawValue = previous
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

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
            "threadID": task.activeConversationID ?? "",
            "provider": task.conversationProvider.rawValue,
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
            let taskID = task.id
            modelContext.delete(task)
            try await saveTaskContext(taskID: taskID)
            try? conversationTranscriptStore().remove(taskID)
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

    func setViewedWorkspaceChange(_ snapshot: WorkspaceViewedChange, taskID: UUID) async throws {
        let task = try requireTask(taskID)
        var snapshots = task.viewedWorkspaceChanges
        snapshots.removeAll { $0.repository == snapshot.repository && $0.path == snapshot.path }
        snapshots.append(snapshot)
        task.viewedWorkspaceChanges = snapshots
        try await saveTaskContext(operation: "BoardTaskManager.setViewedWorkspaceChange", taskID: taskID)
    }

    fileprivate func isRepositoryAttached(_ record: RepositoryWorktreeRecord, to taskID: UUID) throws -> Bool {
        do {
            return try requireTask(taskID).repositoryWorktrees.contains {
                $0.repositoryPath == record.repositoryPath && $0.worktreePath == record.worktreePath
            }
        } catch StationAIManagerError.taskNotFound(_) {
            return false
        }
    }

    func prepareRepositoryWorktrees(
        _ id: UUID,
        fallbackPrompt: String? = nil,
        resolvedTitle: String? = nil
    ) async throws -> BoardTask {
        let initialTask = try requireTask(id)
        let initialRecords = initialTask.repositoryWorktrees
        let pending = initialRecords.filter(\.isPending)
        guard !pending.isEmpty else { return initialTask }
        let branchTitle: String
        if let resolvedTitle, !resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            branchTitle = resolvedTitle
        } else if ["Generating title…", "Untitled task"].contains(initialTask.title) {
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
        let hasSavedConversation = task.hasConversation
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
            fields["hasClaudeSession"] = String(task.claudeSessionID != nil)
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

private struct DeferredRepositoryRemoval: Codable {
    var taskID: UUID
    var record: RepositoryWorktreeRecord
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

    /// The provider new tasks start with. Codex until the user chooses otherwise.
    var defaultConversationProvider: ConversationProvider {
        let value = defaults.string(forKey: WorkspaceSettings.defaultConversationProviderKey)
        return value.flatMap(ConversationProvider.init(rawValue:)) ?? .codex
    }

    func setDefaultConversationProvider(_ value: String) throws {
        StationAIDiagnostics.record("settings.write.started", fields: ["setting": "defaultConversationProvider", "value": value])
        let provider: ConversationProvider
        do {
            provider = try ConversationProvider.parse(value)
        } catch {
            StationAIDiagnostics.record("settings.write.failed", fields: [
                "setting": "defaultConversationProvider", "value": value, "errorCode": "invalid_argument"
            ])
            throw error
        }
        defaults.set(provider.rawValue, forKey: WorkspaceSettings.defaultConversationProviderKey)
        StationAIDiagnostics.record("settings.write.succeeded", fields: ["setting": "defaultConversationProvider", "value": provider.rawValue])
    }

    var defaultParentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    func requireRepositoryRootFolder() throws -> URL {
        guard let rootFolder = defaultParentFolderURL else {
            throw BridgeCommandError(
                code: "settings_required",
                message: "Set the repository root folder in Settings before sending a conversation."
            )
        }
        return rootFolder
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
    private let settingsManager: WorkspaceSettingsManager
    private let worktreeService = StationAIWorktreeService()

    init(
        taskManager: BoardTaskManager? = nil,
        settingsManager: WorkspaceSettingsManager? = nil
    ) {
        self.taskManager = taskManager
        self.settingsManager = settingsManager ?? WorkspaceSettingsManager()
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
        _ = try await taskManager.addRepository(
            taskID,
            repositoryPath: repositoryPath,
            duringActiveConversation: true
        )
        let prepared = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(prepared.repositoryWorktrees.map(\.repositoryPath))
        StationAIDiagnostics.record("workspace.repository.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repositoryPath,
            "repositoryCount": String(prepared.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: prepared)
    }

    @discardableResult
    func addRepositories(_ repositoryPaths: [String], to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.repositories.add.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPaths": repositoryPaths.joined(separator: "\n"),
            "repositoryCount": String(repositoryPaths.count)
        ])
        _ = try await taskManager.addRepositories(
            taskID,
            repositoryPaths: repositoryPaths,
            duringActiveConversation: true
        )
        let taskBeforePreparation = try taskManager.taskModel(taskID)
        if ["Untitled task", "Generating title…"].contains(taskBeforePreparation.title),
           taskBeforePreparation.pendingSubmittedPrompt == nil {
            return BoardTaskRecord(task: taskBeforePreparation)
        }
        let record = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        StationAIDiagnostics.record("workspace.repositories.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: record)
    }

    @discardableResult
    func replaceRepositories(_ repositoryPaths: [String], on taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        StationAIDiagnostics.record("workspace.repositories.replace.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPaths": repositoryPaths.joined(separator: "\n"),
            "repositoryCount": String(repositoryPaths.count)
        ])
        _ = try await taskManager.replaceRepositories(
            taskID,
            repositoryPaths: repositoryPaths,
            duringActiveConversation: true
        )
        let record = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        StationAIDiagnostics.record("workspace.repositories.replace.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: record)
    }

    @discardableResult
    func removeRepository(_ repositoryPath: String, from taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        let record = try await taskManager.removeRepository(
            taskID,
            repositoryPath: repositoryPath,
            duringActiveConversation: true
        )
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        return record
    }

    func reconcileDeferredRepositoryRemovals() async throws {
        guard let taskManager else { return }
        for (intentURL, intent) in try taskManager.deferredRepositoryRemovals() {
            guard try !taskManager.hasConversationTurnReservation(intent.taskID) else { continue }
            do {
                try await taskManager.withConversationTurnReservation(intent.taskID) {
                    try await taskManager.withTaskOperationLock(intent.taskID) {
                        guard FileManager.default.fileExists(atPath: intentURL.path) else { return }
                        if try taskManager.isRepositoryAttached(intent.record, to: intent.taskID) {
                            // The intent is written before detaching the task record. If the save failed or
                            // the service exited before it, leave the still-attached worktree in place.
                            try taskManager.clearDeferredRepositoryRemoval(at: intentURL)
                            return
                        }
                        if try await self.worktreeService.hasChanges(intent.record) {
                            StationAIDiagnostics.record("workspace.repository.deferred_removal_kept_dirty", fields: [
                                "taskID": intent.taskID.uuidString,
                                "repositoryPath": intent.record.repositoryPath,
                                "worktreePath": intent.record.worktreePath
                            ])
                        } else if FileManager.default.fileExists(atPath: intent.record.worktreePath) {
                            try await self.worktreeService.remove(intent.record)
                            StationAIDiagnostics.record("workspace.repository.deferred_removal_succeeded", fields: [
                                "taskID": intent.taskID.uuidString,
                                "repositoryPath": intent.record.repositoryPath,
                                "worktreePath": intent.record.worktreePath
                            ])
                        }
                        try taskManager.clearDeferredRepositoryRemoval(at: intentURL)
                    }
                }
            } catch {
                StationAIDiagnostics.record("workspace.repository.deferred_removal_failed", fields: [
                    "taskID": intent.taskID.uuidString,
                    "repositoryPath": intent.record.repositoryPath,
                    "worktreePath": intent.record.worktreePath,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func changes(for taskID: UUID) async throws -> WorkspaceChangeInventory {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        StationAIDiagnostics.record("workspace.changes.read.started", fields: ["taskID": taskID.uuidString])
        let task = try taskManager.taskModel(taskID)
        let branchFrom = Dictionary(task.repositoryWorktrees.map { (URL(fileURLWithPath: $0.worktreePath, isDirectory: true).standardizedFileURL.path, $0.branchFrom) }) { existing, _ in existing }
        let inventory = try await WorkspaceChangeScanner.inventory(workspaceRoots: roots(for: taskID), branchFromByRepository: branchFrom, viewedChanges: task.viewedWorkspaceChanges)
        StationAIDiagnostics.record("workspace.changes.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "unviewedCount": String(inventory.unviewed.count),
            "viewedCount": String(inventory.viewed.count)
        ])
        return inventory
    }

    func markViewed(for taskID: UUID, repository: String, path: String) async throws {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        let task = try taskManager.taskModel(taskID)
        let inventory = try await changes(for: taskID)
        guard inventory.unviewed.contains(where: { $0.repository == URL(fileURLWithPath: repository).standardizedFileURL.path && $0.path == path }) else {
            throw BridgeCommandError(code: "not_found", message: "The file isn't currently an unviewed change.")
        }
        let snapshot = try await WorkspaceChangeScanner.captureViewedChange(workspaceRoots: task.workspaceRootPaths, repositoryPath: repository, relativePath: path)
        try await taskManager.setViewedWorkspaceChange(snapshot, taskID: taskID)
    }

    func diff(
        for taskID: UUID,
        repository: String,
        path: String,
        group: String
    ) async throws -> WorkspaceFileDiff {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        guard let changeGroup = WorkspaceChangeGroup(rawValue: group) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Change group must be 'unviewed' or 'viewed'.")
        }
        let task = try taskManager.taskModel(taskID)
        let normalizedRepository = URL(fileURLWithPath: repository, isDirectory: true).standardizedFileURL.path
        let branchFrom = task.repositoryWorktrees.first {
            URL(fileURLWithPath: $0.worktreePath, isDirectory: true).standardizedFileURL.path == normalizedRepository
        }?.branchFrom ?? "HEAD"
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
            group: changeGroup,
            branchFrom: branchFrom,
            viewedChanges: task.viewedWorkspaceChanges
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
    var asyncQuestions: [ConversationAsyncQuestion]?
    var activity: ConversationActivity?
    var diff: String?
    var history: ConversationHistory?
    var message: String?
    var imageDataURLs: [String]?
    var userInputRequest: ConversationUserInputRequest?
    var taskStatus: String?
}

@MainActor
final class ConversationManager {
    private var lastReportedTurnOutcomeByTaskID: [UUID: String] = [:]
    private let tasks: BoardTaskManager
    private let clients: ConversationClients
    private let settingsManager: WorkspaceSettingsManager
    private let preferences: UserDefaults
    private var dispatchingQueuedMessages = false
    private static var dispatchingQueuedTaskIDs = Set<UUID>()
    /// Bumped whenever a turn changes what a task's conversation shows (its
    /// transcript or its queue). The turn's own stream reaches only the caller
    /// that started it; any other window follows these instead.
    private(set) static var visibleRevisions: [UUID: Int] = [:]
    private static func bumpVisibleRevision(_ taskID: UUID) { visibleRevisions[taskID, default: 0] += 1 }
    private static var pendingQueuedTaskDispatchIDs = Set<UUID>()
    private var activeSendTaskIDs = Set<UUID>()

    private func shouldDrainMissedSteerImmediately(taskID: UUID) -> Bool {
        guard !activeSendTaskIDs.contains(taskID) else { return false }
        return (try? tasks.hasConversationTurnReservation(taskID)) != true
    }

    init(tasks: BoardTaskManager, clients: ConversationClients, settingsManager: WorkspaceSettingsManager? = nil, preferences: UserDefaults = WorkspaceSettings.preferencesStore) {
        self.tasks = tasks
        self.clients = clients
        self.settingsManager = settingsManager ?? WorkspaceSettingsManager()
        self.preferences = preferences
        if let directory = try? tasks.conversationSteerMailboxDirectory() {
            ConversationSteerMailbox.configure(directory: directory)
        }
    }

    private var transcripts: ConversationTranscriptStore {
        get throws { try tasks.conversationTranscriptStore() }
    }

    private func client(for task: BoardTask) -> ConversationProviderClient {
        clients.client(for: task.conversationProvider)
    }

    private static func historyRoots(_ task: BoardTask) -> [String] {
        task.workspaceRootPaths.isEmpty && task.status == .done
            ? task.repositoryWorktrees.map { $0.repositoryPath }
            : task.workspaceRootPaths
    }

    func history(
        taskID: UUID,
        onActionRequest: @escaping () -> Void = {},
        sensitiveUserInputAnswerValues: [String] = []
    ) async throws -> ConversationHistory {
        let task = try tasks.taskModel(taskID)
        let transcript = try transcripts.read(taskID)
        let answered = try tasks.answeredAsyncQuestionIDs(taskID: taskID)
        // Tasks that never left Codex keep reading their native Codex thread.
        let hasSensitiveRecoveryState = transcript.pendingUserInputRequest != nil
            || transcript.pendingSensitiveUserInputRedaction == true
            || !(transcript.sensitiveTurnIDs ?? []).isEmpty
            || !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        guard !transcript.isEmpty || hasSensitiveRecoveryState else {
            let codex = try await codexHistory(
                task: task,
                onActionRequest: onActionRequest,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues
            )
                ?? ConversationHistory(messages: [], activities: [], diff: nil)
            return ConversationHistory(
                messages: Self.redactingSensitiveMessages(
                    Self.codexMessagesForDisplay(codex.messages, transcript: transcript),
                    turnIDs: [],
                    redactAllMessages: transcript.pendingSensitiveUserInputRedaction == true
                ),
                activities: transcript.pendingSensitiveUserInputRedaction == true
                    ? []
                    : codex.activities.filter { $0.turnID.map(Self.sensitiveCodexTurnIDs(transcript).contains) != true },
                diff: Self.shouldHideCodexDiff(transcript, codex: codex) ? nil : codex.diff,
                answeredAsyncQuestionIDs: answered,
                pendingUserInputRequest: transcript.pendingUserInputRequest
            )
        }
        // Codex can't list a thread before its first turn, so a mixed transcript
        // reads Codex only once a Codex segment owns turns or has recovery state.
        let usesCodex = task.codexThreadID != nil && (
            transcript.segments.contains { $0.provider == .codex && !$0.codexTurnIDs.isEmpty }
                || transcript.pendingSensitiveUserInputRedaction == true
                || transcript.pendingUserInputRequest != nil
                || !(transcript.sensitiveTurnIDs ?? []).isEmpty
                || !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        )
        let codex = usesCodex ? try await codexHistory(
            task: task,
            onActionRequest: onActionRequest,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues
        ) : nil
        let composed = Self.compose(transcript: transcript, codex: codex)
        let visibleMessages = Self.redactingSensitiveMessages(
            composed.messages,
            turnIDs: [],
            redactAllMessages: transcript.pendingSensitiveUserInputRedaction == true
        )
        let modelIDs = transcript.segments.reduce(into: [String: String]()) { result, segment in
            result.merge(segment.codexTurnModelIDs) { existing, _ in existing }
        }
        let messages = visibleMessages.map { message -> ConversationMessage in
            var message = message
            if message.provider == nil, message.turnID != nil { message.provider = .codex }
            if message.modelID == nil, let turnID = message.turnID { message.modelID = modelIDs[turnID] }
            return message
        }
        return ConversationHistory(
            messages: messages,
            activities: transcript.pendingSensitiveUserInputRedaction == true ? [] : composed.activities,
            diff: transcript.pendingSensitiveUserInputRedaction == true ? nil : composed.diff,
            answeredAsyncQuestionIDs: answered,
            pendingUserInputRequest: transcript.pendingUserInputRequest,
            providerBoundaries: composed.providerBoundaries
        )
    }

    /// Answers a live provider request when its process still owns the control
    /// request. After a restart, replays the answer as a new provider turn using
    /// the durable question saved in the task transcript.
    func answerUserInput(
        taskID: UUID,
        request: ConversationUserInputRequest,
        answers: [String: [String]],
        modelID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> Bool {
        let task = try tasks.taskModel(taskID)
        guard task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task for follow-up work.")
        }
        guard request.threadID == task.activeConversationID else {
            throw BridgeCommandError(code: "invalid_transition", message: "That question no longer belongs to this conversation.")
        }
        let transcript = try transcripts.read(taskID)
        guard transcript.pendingUserInputRequest == request else {
            throw BridgeCommandError(code: "not_found", message: "That pending question is no longer available.")
        }
        let questionsByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        let valid = Set(answers.keys) == Set(questionsByID.keys) && answers.allSatisfy { id, values in
            guard !values.isEmpty, let question = questionsByID[id] else { return false }
            return values.allSatisfy { value in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && (question.allowsOther || question.options.isEmpty || question.options.contains { $0.label == value })
            }
        }
        guard valid else {
            throw BridgeCommandError(code: "invalid_argument", message: "Supply a non-empty answer for every question.")
        }

        let client = client(for: task)
        if client.answerUserInput(requestID: request.id, threadID: request.threadID, answers: answers) {
            try clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
            if request.isBlocking {
                let resumed = try await tasks.resumeWaitingResponseAfterUserInput(taskID)
                onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed.status))
            }
            return true
        }

        guard !(try tasks.hasConversationTurnReservation(taskID)) else {
            throw BridgeCommandError(code: "invalid_transition", message: "This question is still active in another StationAI process. Answer it there or reopen after that process ends.")
        }
        let answerLines = request.questions.map { question in
            let answer = (answers[question.id] ?? []).joined(separator: ", ")
            return "Question: \(question.question)\nAnswer: \(answer)"
        }
        let sensitiveValues = request.questions
            .filter(\.isSecret)
            .flatMap { answers[$0.id] ?? [] }
            .map { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        let requiresSensitiveAnswerRedaction = request.questions.contains(where: \.isSecret)
        let sensitiveCodexTurnIDsBeforeRecovery = Set(try transcripts.read(taskID).sensitiveCodexTurnIDs ?? [])
        try transcripts.mutate(taskID) { transcript in
            transcript.pendingSensitiveUserInputRedaction = true
        }
        let secretNote = request.questions.contains(where: \.isSecret)
            ? "The user re-entered the requested secret answer(s) after restart. Apply them now; do not ask for them again."
            : ""
        let recoveryPrompt = """
        Continue this conversation by applying the user's answer to the pending question from the prior StationAI session. The prior provider process ended, so this answer arrives as a new turn.

        \(secretNote)

        \(answerLines.joined(separator: "\n\n"))
        """
        _ = try await send(
            taskID: taskID,
            text: recoveryPrompt,
            mode: request.mode,
            modelID: modelID,
            onUpdate: onUpdate,
            sensitiveUserInputAnswerValues: sensitiveValues,
            requiresSensitiveAnswerRedaction: requiresSensitiveAnswerRedaction,
            hideSensitiveRecoveryPrompt: true
        )
        if requiresSensitiveAnswerRedaction {
            try transcripts.mutate(taskID) { transcript in
                let recoveryTurnIDs = Set(transcript.sensitiveCodexTurnIDs ?? []).subtracting(sensitiveCodexTurnIDsBeforeRecovery)
                var storedMessages = transcript.sensitiveCodexTurnMessages ?? [:]
                for turnID in recoveryTurnIDs {
                    storedMessages[turnID] = storedMessages[turnID]?.map { message in
                        guard message.role == .assistant else { return message }
                        var hidden = message
                        hidden.text = "[Response to private answer hidden]"
                        hidden.asyncQuestions = nil
                        return hidden
                    }
                }
                transcript.sensitiveCodexTurnMessages = storedMessages
            }
        }
        try clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
        return true
    }

    func answerUserInput(
        taskID: UUID,
        requestID: String,
        answers: [String: [String]],
        modelID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> Bool {
        guard let request = try transcripts.read(taskID).pendingUserInputRequest,
              request.id == requestID else {
            throw BridgeCommandError(code: "not_found", message: "That pending question is no longer available.")
        }
        return try await answerUserInput(
            taskID: taskID, request: request, answers: answers, modelID: modelID, onUpdate: onUpdate
        )
    }

    /// Repairs the historical shared-callback bug without answering the question
    /// or resuming its provider. The native thread identity determines ownership.
    func repairPendingUserInput(taskID: UUID, sourceTaskID: UUID) async throws -> ConversationUserInputRequest {
        let task = try tasks.taskModel(taskID)
        let source = try tasks.taskModel(sourceTaskID)
        guard taskID != sourceTaskID, task.status != .done,
              let threadID = task.activeConversationID,
              source.activeConversationID != threadID else {
            throw BridgeCommandError(code: "invalid_transition", message: "Choose the question's original conversation and a different source task.")
        }
        let request = try transcripts.reassignPendingUserInput(from: sourceTaskID, to: taskID, threadID: threadID)
        if request.isBlocking, task.status == .inProgress {
            _ = try await tasks.transitionLifecycleStatus(taskID, from: .inProgress, to: .waitingResponse)
        }
        StationAIDiagnostics.record("conversation.user_input.repaired", fields: [
            "taskID": taskID.uuidString, "sourceTaskID": sourceTaskID.uuidString,
            "threadID": threadID, "requestID": request.id
        ])
        return request
    }

    private func persistPendingUserInputRequest(_ request: ConversationUserInputRequest, taskID: UUID) throws {
        guard try tasks.taskModel(taskID).activeConversationID == request.threadID else {
            throw BridgeCommandError(code: "invalid_transition", message: "The question belongs to another conversation.")
        }
        try transcripts.mutate(taskID) { transcript in
            transcript.pendingUserInputRequest = request
        }
    }

    private func clearPendingUserInputRequest(taskID: UUID, requestID: String) throws {
        try transcripts.mutate(taskID) { transcript in
            guard transcript.pendingUserInputRequest?.id == requestID else { return }
            transcript.pendingUserInputRequest = nil
        }
    }

    /// Publishes an image produced by an agent as a durable assistant message.
    /// This is StationAI-owned presentation state, so both provider runtimes use
    /// the same transcript path.
    func publishImage(taskID: UUID, path: String, caption: String = "") async throws -> ConversationMessage {
        let task = try tasks.taskModel(taskID)
        let provider = task.conversationProvider
        let codexClient = clients.codex
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000 else {
            throw BridgeCommandError(code: "invalid_argument", message: "The image must be smaller than 10 MB.")
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        default: throw BridgeCommandError(code: "invalid_argument", message: "Use a PNG or JPEG image.")
        }
        let image = "data:\(mime);base64,\(data.base64EncodedString())"
        guard Self.isValidImageDataURL(image) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The file is not a valid PNG or JPEG image.")
        }
        let activeCodexThreadID = provider == .codex ? task.activeConversationID : nil
        let activeCodexTurnID = activeCodexThreadID.flatMap { threadID in
            codexClient.activeTurnID(for: threadID)
                ?? ConversationSteerMailbox.activeTurnID(threadID: threadID)
        }
        let isActiveCodexPublication = activeCodexThreadID != nil && activeCodexTurnID != nil
        // A Codex thread can reject a history read while its turn is writing.
        // An agent publishes its generated image from inside that turn, so use
        // the active turn identity and attach the image to StationAI's transcript.
        // History composition positions it after that turn's native messages.
        let existingHistory = isActiveCodexPublication ? nil : try await history(taskID: taskID)
        let message = ConversationMessage(
            id: UUID().uuidString.lowercased(), role: .assistant,
            text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            imageDataURLs: [image], phase: "agent_image", turnID: activeCodexTurnID,
            timelineOrder: existingHistory.flatMap { history in
                provider == .codex
                    ? (history.messages.compactMap(\.timelineOrder).max() ?? history.messages.count - 1) + 1
                    : nil
            },
            provider: provider
        )
        let activeClaudeTurn = provider == .claude
            && task.activeConversationID.map {
                client(for: task).isTurnActive(threadID: $0)
                    || client(for: task).isTurnActiveInProcess(threadID: $0)
                    || ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: $0) != nil
            } == true
        try transcripts.mutate(taskID) { transcript in
            var segment = transcript.segments.last.flatMap { $0.provider == provider ? $0 : nil }
            if segment == nil {
                let created = ConversationTranscript.Segment(id: UUID().uuidString, provider: provider, startedAt: .now, handoffDelivered: true)
                transcript.segments.append(created)
                segment = created
            }
            guard let segment else { return }
            if provider == .codex, let index = transcript.segments.firstIndex(where: { $0.id == segment.id }) {
                if let activeCodexTurnID, !transcript.segments[index].codexTurnIDs.contains(activeCodexTurnID) {
                    transcript.segments[index].codexTurnIDs.append(activeCodexTurnID)
                }
                let claimed = Set(transcript.segments.flatMap(\.codexTurnIDs))
                let ids = Self.orderedTurnIDs(existingHistory?.messages ?? [])
                transcript.segments[index].codexTurnIDs += ids.filter { !claimed.contains($0) }
            }
            if activeClaudeTurn,
               let index = transcript.turns.indices.last,
               transcript.turns[index].segmentID == segment.id {
                var attributed = message
                attributed.turnID = transcript.turns[index].id
                transcript.turns[index].messages.append(attributed)
            } else {
                transcript.turns.append(.init(id: "agent-image-\(message.id)", segmentID: segment.id, messages: [message]))
            }
        }
        return message
    }

    private func codexHistory(
        task: BoardTask,
        onActionRequest: @escaping () -> Void,
        sensitiveUserInputAnswerValues: [String] = []
    ) async throws -> ConversationHistory? {
        guard let threadID = task.codexThreadID else { return nil }
        let taskID = task.id
        let codex = clients.codex
        let recoveryTranscript = try? transcripts.read(taskID)
        let hasSensitiveRecoveryState = recoveryTranscript?.pendingUserInputRequest != nil
            || recoveryTranscript?.pendingSensitiveUserInputRedaction == true
            || !(recoveryTranscript?.sensitiveTurnIDs ?? []).isEmpty
            || !(recoveryTranscript?.sensitiveCodexTurnIDs ?? []).isEmpty
        let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let settings = settingsManager
        let repositoryRoot = settings.defaultParentFolderURL
        StationAIDiagnostics.record("conversation.history.started", fields: codex.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "taskStatus": task.status.rawValue
        ]))
        do {
            let history = try await codex.loadThread(
                id: threadID,
                workspace: workspace,
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: repositoryRoot?.path
                ),
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                sensitiveConversation: hasSensitiveRecoveryState,
                onActionRequest: onActionRequest
            )
            let savedDurations = tasks.conversationActivityDurations(taskID: taskID)
            let activities = history.activities.map { activity -> ConversationActivity in
                var activity = activity
                if activity.durationMs == nil { activity.durationMs = savedDurations[activity.id] }
                return activity
            }
            StationAIDiagnostics.record("conversation.history.succeeded", fields: codex.diagnosticFields([
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "messageCount": String(history.messages.count),
                "activityCount": String(history.activities.count)
            ]))
            return ConversationHistory(messages: history.messages, activities: activities, diff: history.diff)
        } catch {
            var fields: [String: String]
            if hasSensitiveRecoveryState && sensitiveUserInputAnswerValues.isEmpty {
                // After a restart the answer is deliberately not persisted, so
                // provider supplied error text cannot be safely scrubbed.
                fields = ["errorDescription": "History for a private recovery conversation could not be loaded."]
            } else {
                fields = StationAIDiagnostics.errorFields(
                    error,
                    redacting: [task.title, task.savedPrompt ?? ""] + sensitiveUserInputAnswerValues
                )
            }
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["taskStatus"] = task.status.rawValue
            fields.merge(codex.diagnosticFields()) { _, new in new }
            StationAIDiagnostics.record("conversation.history.failed", fields: fields)
            if hasSensitiveRecoveryState {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "History for a private recovery conversation could not be loaded."
                )
            }
            throw error
        }
    }

    /// Orders every visible element by provider segment, then by its position
    /// within that provider's own timeline, and inserts a divider wherever the
    /// provider changes.
    static func compose(transcript: ConversationTranscript, codex: ConversationHistory?) -> ConversationHistory {
        enum Element {
            case message(ConversationMessage)
            case compaction(ConversationActivity)
        }
        var elements: [(segment: Int, order: Int, tieBreak: Int, element: Element)] = []
        let segments = transcript.segments
        let lastCodexSegment = segments.lastIndex { $0.provider == .codex } ?? -1
        var codexSegmentByTurn: [String: Int] = [:]
        for (index, segment) in segments.enumerated() where segment.provider == .codex {
            for turnID in segment.codexTurnIDs where codexSegmentByTurn[turnID] == nil {
                codexSegmentByTurn[turnID] = index
            }
        }
        func codexSegment(_ turnID: String?) -> Int {
            turnID.flatMap { codexSegmentByTurn[$0] } ?? lastCodexSegment
        }
        var codexTurnSegment: Int?
        let sensitiveTurnIDs = Self.sensitiveCodexTurnIDs(transcript)
        let safeCodexMessages = Self.codexMessagesForDisplay(codex?.messages ?? [], transcript: transcript)
        func transcriptOrder(for message: ConversationMessage, fallback: Int) -> (order: Int, tieBreak: Int) {
            guard message.provider == .codex, message.phase == "agent_image" else {
                return (message.timelineOrder ?? fallback, 0)
            }
            if let order = message.timelineOrder { return (order, 0) }
            let relevantMessages = message.turnID.map { turnID in
                safeCodexMessages.filter { $0.turnID == turnID }
            } ?? safeCodexMessages
            guard let lastTurnOrder = relevantMessages.compactMap(\.timelineOrder).max() else {
                return (fallback, 0)
            }
            // Keep the image just after the final native item of its turn and
            // ahead of the next turn's first item, even when their orders touch.
            return (lastTurnOrder, fallback + 1)
        }
        for (offset, message) in safeCodexMessages.enumerated() {
            let segment = message.turnID.map(codexSegment) ?? codexTurnSegment ?? lastCodexSegment
            codexTurnSegment = segment
            var attributed = message
            attributed.provider = attributed.provider ?? .codex
            if attributed.modelID == nil, let turnID = attributed.turnID {
                attributed.modelID = segments.compactMap { $0.codexTurnModelIDs[turnID] }.first
            }
            elements.append((segment, message.timelineOrder ?? offset, 0, .message(attributed)))
        }
        let privateReminderTurnIDs = Set(codex?.messages.filter {
            $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID) ?? [])
        let privateTranscriptReminderTurnIDs = Set(transcript.turns.compactMap { turn in
            turn.messages.contains { $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text) } ? turn.id : nil
        })
        let allSensitiveTurnIDs = Set(transcript.sensitiveTurnIDs ?? [])
        let codexActivities = transcript.pendingSensitiveUserInputRedaction == true
            ? []
            : (codex?.activities ?? []).filter {
                $0.turnID.map { sensitiveTurnIDs.contains($0) || privateReminderTurnIDs.contains($0) } != true
            }
        for activity in codexActivities where activity.isContextCompaction {
            let order = activity.timelineOrder ?? Int.max
            let precedingTurn = codex?.messages.last { ($0.timelineOrder ?? 0) < order }?.turnID
            elements.append((codexSegment(activity.turnID ?? precedingTurn), order, 0, .compaction(activity)))
        }
        var localOrder = 0
        for turn in transcript.turns {
            if privateTranscriptReminderTurnIDs.contains(turn.id) { continue }
            let segment = transcript.segmentIndex(of: turn.segmentID) ?? segments.count
            for message in turn.messages {
                let position = transcriptOrder(for: message, fallback: localOrder)
                elements.append((segment, position.order, position.tieBreak, .message(message)))
                localOrder += 1
            }
            for activity in turn.activities where activity.turnID.map(allSensitiveTurnIDs.contains) != true {
                if activity.isContextCompaction {
                    elements.append((segment, activity.timelineOrder ?? localOrder, 0, .compaction(activity)))
                }
                localOrder += 1
            }
        }
        elements.sort { ($0.segment, $0.order, $0.tieBreak) < ($1.segment, $1.order, $1.tieBreak) }

        var messages: [ConversationMessage] = []
        var compactions: [ConversationActivity] = []
        var lastMessageBeforeSegment: [Int: String] = [:]
        var lastMessageID: String?
        var nextSegment = 0
        for (order, item) in elements.enumerated() {
            while nextSegment <= item.segment, nextSegment < segments.count {
                lastMessageBeforeSegment[nextSegment] = lastMessageID
                nextSegment += 1
            }
            switch item.element {
            case .message(var message):
                message.timelineOrder = order
                messages.append(message)
                lastMessageID = message.id
            case .compaction(var activity):
                activity.timelineOrder = order
                compactions.append(activity)
            }
        }
        while nextSegment < segments.count {
            lastMessageBeforeSegment[nextSegment] = lastMessageID
            nextSegment += 1
        }
        var boundaries: [ConversationProviderBoundary] = []
        for index in segments.indices.dropFirst() where segments[index].provider != segments[index - 1].provider {
            boundaries.append(ConversationProviderBoundary(
                id: "provider-boundary-\(segments[index].id)",
                provider: segments[index].provider,
                afterMessageID: lastMessageBeforeSegment[index] ?? nil
            ))
        }

        // Activity details follow the latest turn, as each provider reports them.
        let activities: [ConversationActivity]
        let diff: ConversationTurnDiff?
        if segments.last?.provider == .claude {
            let visibleTurns = transcript.turns.filter { !privateTranscriptReminderTurnIDs.contains($0.id) }
            let latestTurn = visibleTurns.last
            let subagents = visibleTurns.dropLast().flatMap { $0.activities.filter(\.isSubagent) }
            activities = subagents + (latestTurn?.activities ?? []) + compactions
            diff = nil
        } else {
            activities = codexActivities.filter { !$0.isContextCompaction } + compactions
            diff = Self.shouldHideCodexDiff(transcript, codex: codex) ? nil : codex?.diff
        }
        return ConversationHistory(
            messages: messages,
            activities: activities,
            diff: diff,
            pendingUserInputRequest: transcript.pendingUserInputRequest,
            providerBoundaries: boundaries
        )
    }

    /// Reads a subagent's work without resuming or changing its turn.
    func subagentHistory(taskID: UUID, activity: ConversationActivity) async throws -> ConversationHistory {
        let task = try tasks.taskModel(taskID)
        guard let childID = activity.childThreadID else {
            throw BridgeCommandError(code: "invalid_argument", message: "That activity is not a subagent.")
        }
        let isClaudeSubagent = try transcripts.read(taskID).turns.contains { turn in
            turn.activities.contains { $0.childThreadID == childID }
        }
        guard isClaudeSubagent else {
            let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
            return try await clients.codex.inspectThreadReadOnly(id: childID, workspace: workspace)
        }
        // Claude Code reports a subagent's prompt summary and final report to its
        // parent; StationAI shows those rather than its private sidechain.
        let report = ConversationMessage(id: "\(childID)-report", role: .assistant, text: activity.detail, phase: "final_answer", provider: .claude)
        return ConversationHistory(messages: [report], activities: [], diff: nil)
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
        } else if let environmentRoot = StationAIProcessEnvironment.current["CODEX_HOME"], !environmentRoot.isEmpty {
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
        var conversationIDs = try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        // Claude turns live in StationAI's transcript store rather than a provider session file.
        let store = try transcripts
        let needle = normalizedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for task in completed where !titleIDs.contains(task.id) && !conversationIDs.contains(task.id) {
            try Task.checkCancellation()
            let matches = try store.read(task.id).turns.contains { turn in
                turn.messages.contains { $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
            }
            if matches { conversationIDs.insert(task.id) }
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

    private func modelCacheKey(for provider: ConversationProvider) -> String {
        "conversation.models.cache.\(provider.rawValue)"
    }

    private func selectedModelKey(for provider: ConversationProvider) -> String {
        "conversation.model.selected.\(provider.rawValue)"
    }

    func cachedModels(taskID: UUID) throws -> [ConversationModelOption] {
        let task = try tasks.taskModel(taskID)
        return try cachedModels(provider: task.conversationProvider)
    }

    func cachedModels(taskID: UUID, provider: ConversationProvider) throws -> [ConversationModelOption] {
        _ = try tasks.taskModel(taskID)
        return try cachedModels(provider: provider)
    }

    private func cachedModels(provider: ConversationProvider) throws -> [ConversationModelOption] {
        guard let data = preferences.data(forKey: modelCacheKey(for: provider)),
              let models = try? JSONDecoder().decode([ConversationModelOption].self, from: data),
              !models.isEmpty else { return [] }
        return models.newestVersionPerFamily()
    }

    func models(taskID: UUID) async throws -> [ConversationModelOption] {
        StationAIDiagnostics.record("conversation.models.read.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.taskModel(taskID)
        let workspace = try ConversationWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let models = try await client(for: task).availableModels(workspace: workspace).newestVersionPerFamily()
        if let data = try? JSONEncoder().encode(models) {
            preferences.set(data, forKey: modelCacheKey(for: task.conversationProvider))
        }
        StationAIDiagnostics.record("conversation.models.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "provider": task.conversationProvider.rawValue,
            "modelCount": String(models.count),
            "modelIDs": models.map(\.id).joined(separator: ",")
        ])
        return models
    }

    func effort(taskID: UUID) throws -> ConversationEffort {
        ConversationEffort(rawValue: try tasks.taskModel(taskID).conversationEffort) ?? .medium
    }

    func modelID(taskID: UUID) throws -> String? {
        let task = try tasks.taskModel(taskID)
        let key = selectedModelKey(for: task.conversationProvider)
        if let selectedModelID = preferences.string(forKey: key) {
            return selectedModelID
        }

        // One-time migration from the previous per-task preference.
        if let legacyModelID = task.conversationModelID {
            preferences.set(legacyModelID, forKey: key)
            return legacyModelID
        }
        return nil
    }

    func setEffort(taskID: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await tasks.setConversationEffort(taskID, effort: effort)
    }

    func setModelID(taskID: UUID, modelID: String) throws {
        let task = try tasks.taskModel(taskID)
        preferences.set(modelID, forKey: selectedModelKey(for: task.conversationProvider))
    }

    // MARK: - Providers

    /// Detected native capabilities, so switching can show what differs. StationAI
    /// starts Codex without MCP servers, apps, or hooks; Claude Code uses its own
    /// configuration.
    func providerCapabilities(taskID: UUID) async throws -> [ConversationProviderCapabilities] {
        let task = try tasks.taskModel(taskID)
        let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let codex = ConversationProviderCapabilities(
            provider: .codex,
            isAvailable: CodexAppServerClient.isInstalled,
            supportsGoals: true,
            notes: ["StationAI runs Codex without MCP servers, apps, or hooks.", "Goals are available."]
        )
        return [codex, await clients.claude.capabilities(workspace: workspace)]
    }

    /// Changes the provider that runs the task's next turn. A switch waits for the
    /// current turn, pending questions, queued follow-ups, and background
    /// subagents to settle, and records a boundary in the transcript.
    func setProvider(taskID: UUID, provider: ConversationProvider) async throws -> BoardTaskRecord {
        var task = try tasks.taskModel(taskID)
        StationAIDiagnostics.record("conversation.provider.switch.started", fields: [
            "taskID": taskID.uuidString, "from": task.conversationProvider.rawValue, "to": provider.rawValue
        ])
        guard task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task to use another provider.")
        }
        guard task.conversationProvider != provider else { return try tasks.get(taskID) }
        guard task.hasConversation else {
            return try await tasks.setConversationProvider(taskID, provider: provider)
        }
        let history = try await requireSettledConversation(task)
        let transcript = try transcripts.read(taskID)
        var codexTurnIDs: [String] = []
        if history.activities.contains(where: { $0.isSubagent && $0.isActive }) {
            throw Self.switchBlocked("Subagents are still running. Wait for them to finish before switching providers.")
        }
        if transcript.isEmpty, task.conversationProvider == .codex {
            // A Codex-only task's turns all precede its first boundary. Tracked
            // segments claim their Codex turns as each turn completes.
            codexTurnIDs = Self.orderedTurnIDs(history.messages)
        }
        let claimed = Set(transcript.segments.flatMap(\.codexTurnIDs))
        try transcripts.mutate(taskID) { transcript in
            if transcript.segments.isEmpty {
                transcript.segments.append(.init(id: UUID().uuidString, provider: task.conversationProvider, startedAt: .now, handoffDelivered: true))
            }
            if var last = transcript.segments.last, last.provider == .codex {
                last.codexTurnIDs += codexTurnIDs.filter { !claimed.contains($0) && !last.codexTurnIDs.contains($0) }
                transcript.segments[transcript.segments.count - 1] = last
            }
            // A segment with no turns can be replaced instead of leaving an empty boundary.
            if let last = transcript.segments.last, transcript.turns(in: last).isEmpty, last.codexTurnIDs.isEmpty, transcript.segments.count > 1 {
                transcript.segments.removeLast()
            }
            if transcript.segments.last?.provider != provider {
                transcript.segments.append(.init(id: UUID().uuidString, provider: provider, startedAt: .now))
            }
        }
        task = try tasks.taskModel(taskID)
        let record = try await tasks.setConversationProvider(taskID, provider: provider)
        StationAIDiagnostics.record("conversation.provider.switch.succeeded", fields: [
            "taskID": taskID.uuidString, "provider": provider.rawValue,
            "segmentCount": String((try? transcripts.read(taskID).segments.count) ?? 0)
        ])
        return record
    }

    /// Returns the visible history once nothing is still running or waiting.
    private func requireSettledConversation(_ task: BoardTask) async throws -> ConversationHistory {
        let client = client(for: task)
        if try tasks.hasConversationTurnReservation(task.id) || activeSendTaskIDs.contains(task.id) {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if let conversationID = task.activeConversationID,
           client.isTurnActive(threadID: conversationID) || client.isTurnActiveInProcess(threadID: conversationID)
            || client.activeTurnOwnerProcessID(threadID: conversationID) != nil {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if task.pendingSubmittedPrompt != nil {
            throw Self.switchBlocked("Wait for the submitted prompt to start before switching providers.")
        }
        if !(try tasks.queuedConversationMessages(taskID: task.id)).isEmpty {
            throw Self.switchBlocked("Send or remove the queued follow-ups before switching providers.")
        }
        let history = try await self.history(taskID: task.id)
        if history.pendingUserInputRequest != nil {
            throw Self.switchBlocked("Answer the pending structured question before switching providers.")
        }
        let answered = Set(history.answeredAsyncQuestionIDs)
        if history.messages.contains(where: { $0.asyncQuestions != nil && !answered.contains($0.id) }),
           task.status == .waitingResponse {
            throw Self.switchBlocked("Answer the pending question before switching providers.")
        }
        return history
    }

    private static func switchBlocked(_ message: String) -> BridgeCommandError {
        StationAIDiagnostics.record("conversation.provider.switch.blocked", fields: ["reason": message])
        return BridgeCommandError(code: "invalid_transition", message: message)
    }

    private static func orderedTurnIDs(_ messages: [ConversationMessage]) -> [String] {
        var seen = Set<String>()
        return messages.compactMap(\.turnID).filter { seen.insert($0).inserted }
    }

    // MARK: - Goals (Codex only)

    func goal(taskID: UUID, objective: String? = nil, action: String = "get", observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        var task = try tasks.taskModel(taskID)
        guard ["get", "set", "pause", "resume", "clear"].contains(action) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Goal action must be get, set, pause, resume, or clear.")
        }
        guard task.conversationProvider.supportsGoals else {
            guard action == "get" else {
                throw BridgeCommandError(code: "invalid_transition", message: "Goals are available only in Codex conversations. Switch this task to Codex to use a Goal.")
            }
            return nil
        }
        let client = clients.codex
        guard action == "get" || task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task to change its goal.")
        }
        if action == "set" {
            guard let objective else { throw StationAIManagerError.invalidMessage }
            let value = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 4000 else {
                throw BridgeCommandError(code: "invalid_argument", message: "Goal text must contain 1 to 4,000 characters.")
            }
        }
        if task.codexThreadID == nil {
            guard action == "set" else { return nil }
            let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let workspace = try ConversationWorkspaceContext(roots: roots)
            let id = try await client.startThread(
                workspace: workspace,
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: settingsManager.defaultParentFolderURL?.path
                )
            )
            _ = try await tasks.persistConversationID(taskID, provider: .codex, id: id)
            task = try tasks.taskModel(taskID)
        }
        guard let threadID = task.codexThreadID else { return nil }
        let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
        switch action {
        case "get": return try await client.getGoal(threadID: threadID, workspace: workspace)
        case "set":
            let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousGoal = try await client.getGoal(threadID: threadID, workspace: workspace)
            let goal = try await client.setGoal(threadID: threadID, objective: normalizedObjective, status: "active", workspace: workspace, observeRuntime: observeRuntime)
            if let goal, let normalizedObjective {
                CodexGoalGenerationStore.recordSet(taskID: taskID, objective: normalizedObjective, previousGoal: previousGoal, goal: goal, defaults: preferences)
            }
            _ = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
            return goal
        case "pause": return try await client.setGoal(threadID: threadID, status: "paused", workspace: workspace)
        case "resume": return try await client.setGoal(threadID: threadID, status: "active", workspace: workspace)
        case "clear":
            let previousGoal = try await client.getGoal(threadID: threadID, workspace: workspace)
            try await client.clearGoal(threadID: threadID, workspace: workspace)
            CodexGoalGenerationStore.recordClear(taskID: taskID, goal: previousGoal, defaults: preferences)
            return nil
        default: throw BridgeCommandError(code: "invalid_argument", message: "Goal action must be get, set, pause, resume, or clear.")
        }
    }

    // MARK: - Turn control

    func interrupt(taskID: UUID) async throws -> Bool {
        StationAIDiagnostics.record("conversation.interrupt.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.activeConversationID else {
            StationAIDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_thread"
            ])
            return false
        }
        let providerClient = client(for: task)
        guard providerClient.isTurnActive(threadID: threadID)
                || providerClient.activeTurnOwnerProcessID(threadID: threadID) != nil else {
            StationAIDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_active_turn"
            ])
            return false
        }
        // A user-requested stop is a resumable pause. Persist that intent before
        // asking the provider so the task leaves In Progress as soon as Stop is
        // clicked, even when the provider is still thinking or the interrupt
        // acknowledgment takes time.
        let pauseRevision = try await tasks.transitionLifecycleStatus(
            taskID,
            from: .inProgress,
            to: .waitingResponse
        )
        let interrupted: Bool
        do {
            interrupted = try await providerClient.interruptActiveTurn(threadID: threadID)
        } catch {
            if let pauseRevision,
               (providerClient.isTurnActive(threadID: threadID)
                    || providerClient.activeTurnOwnerProcessID(threadID: threadID) != nil) {
                _ = try? await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: pauseRevision)
            }
            throw error
        }
        if !interrupted, let pauseRevision {
            _ = try await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: pauseRevision)
        }
        StationAIDiagnostics.record("conversation.interrupt.finished", fields: [
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "provider": task.conversationProvider.rawValue,
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
        guard let threadID = task.activeConversationID else { return false }
        // The running turn records and streams the steered input itself.
        return try await client(for: task).steerActiveTurn(threadID: threadID, text: normalizedText, imageDataURLs: imageDataURLs)
    }

    func answerUserInput(taskID: UUID, requestID: String, threadID: String, answers: [String: [String]]) throws -> Bool {
        client(for: try tasks.taskModel(taskID)).answerUserInput(requestID: requestID, threadID: threadID, answers: answers)
    }

    func answerAsyncQuestion(taskID: UUID, question: ConversationMessage, answers: [String]) async throws -> (text: String, queued: Bool, history: ConversationHistory?) {
        let providerName = try tasks.taskModel(taskID).conversationProvider.displayName
        guard let questions = question.asyncQuestions, !questions.isEmpty, questions.count == answers.count else {
            throw BridgeCommandError(code: "invalid_argument", message: "Supply one answer for every question in the \(providerName) item.")
        }
        guard !(try tasks.answeredAsyncQuestionIDs(taskID: taskID)).contains(question.id) else {
            throw BridgeCommandError(code: "invalid_transition", message: "This \(providerName) question has already been answered.")
        }
        guard try !queuedMessages(taskID: taskID).contains(where: { $0.asyncQuestionItemID == question.id }) else {
            throw BridgeCommandError(code: "invalid_transition", message: "An answer to this \(providerName) question is already pending.")
        }
        let normalized = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty }) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Question answers can't be blank.")
        }
        let reply = zip(questions, normalized).map { pair in "\(pair.0.title): \(pair.1)" }.joined(separator: "\n")
        let steered = try await steer(taskID: taskID, text: reply)
        if steered {
            try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: question.id)
            return (reply, false, nil)
        }
        let item = try await queueMissedSteer(taskID: taskID, text: reply, asyncQuestionItemID: question.id)
        let stillQueued = try queuedMessages(taskID: taskID).contains { $0.id == item.id }
        if !stillQueued { try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: question.id) }
        return (reply, stillQueued, stillQueued ? nil : try await history(taskID: taskID))
    }

    /// The question persisted for this conversation, readable without its provider.
    func savedUserInputRequest(taskID: UUID) throws -> ConversationUserInputRequest? {
        try transcripts.read(taskID).pendingUserInputRequest
    }

    func queuedMessages(taskID: UUID) throws -> [QueuedConversationMessage] {
        try tasks.queuedConversationMessages(taskID: taskID)
    }

    func answeredAsyncQuestionIDs(taskID: UUID) throws -> [String] {
        try tasks.answeredAsyncQuestionIDs(taskID: taskID)
    }

    func queueMessage(taskID: UUID, text: String, imageDataURLs: [String] = [], asyncQuestionItemID: String? = nil) throws -> QueuedConversationMessage {
        defer { Self.bumpVisibleRevision(taskID) }
        return try tasks.enqueueConversationMessage(
            taskID: taskID,
            text: text, imageDataURLs: imageDataURLs, asyncQuestionItemID: asyncQuestionItemID
        )
    }

    func queueMissedSteer(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        asyncQuestionItemID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws -> QueuedConversationMessage {
        let item = try queueMessage(taskID: taskID, text: text, imageDataURLs: imageDataURLs, asyncQuestionItemID: asyncQuestionItemID)
        if shouldDrainMissedSteerImmediately(taskID: taskID) {
            await dispatchQueuedMessages(
                taskID: taskID,
                mode: .code,
                modelID: nil,
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
        defer { Self.bumpVisibleRevision(taskID) }
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
            if accepted {
                if let itemID = item.asyncQuestionItemID {
                    try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: itemID)
                }
                try tasks.finishQueuedMessageSteering(taskID: taskID, messageID: messageID, accepted: true)
            }
            else {
                try tasks.requeueMissedSteer(taskID: taskID, messageID: messageID)
                if shouldDrainMissedSteerImmediately(taskID: taskID) {
                    await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: nil, onlyMessageID: messageID, onUpdate: { _ in }, onUserInput: { _ in })
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
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws -> Bool {
        try tasks.retryQueuedMessage(taskID: taskID, messageID: messageID)
        await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: nil, onlyMessageID: messageID, onUpdate: onUpdate, onUserInput: onUserInput)
        return try !tasks.queuedConversationMessages(taskID: taskID).contains { $0.id == messageID }
    }

    /// Sends a turn with the task's current provider. A nil model uses that
    /// provider's default, so queued and resumed turns follow a provider switch.
    func send(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode = .code,
        modelID: String? = nil,
        userInputAnswers: [String: [String]] = [:],
        retainQueuedMessagesOnFailure: Bool = true,
        statusBeforeSubmission: TaskStatus? = nil,
        onTurnStarting: (() -> Void)? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in },
        sensitiveUserInputAnswerValues: [String] = [],
        requiresSensitiveAnswerRedaction: Bool = false,
        hideSensitiveRecoveryPrompt: Bool = false,
        hideInternalOutcomeReminder: Bool = false
    ) async throws -> ConversationHistory {
        let streamUpdate = onUpdate
        let onUpdate: (ConversationUpdate) -> Void = { update in
            if update.type == "queue_changed" || update.type == "steered_message" { Self.bumpVisibleRevision(taskID) }
            streamUpdate(update)
        }
        defer { Self.bumpVisibleRevision(taskID) }
        let operationClient = client(for: try tasks.taskModel(taskID))
        operationClient.beginConversationOperation()
        defer { operationClient.finishConversationOperation() }
        activeSendTaskIDs.insert(taskID)
        defer { activeSendTaskIDs.remove(taskID) }
        let history: ConversationHistory
        do {
            history = try await tasks.withConversationTurnReservation(taskID) {
                do {
                    self.lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
                    let result = try await self.sendReserved(
                        taskID: taskID,
                        text: text,
                        imageDataURLs: imageDataURLs,
                        mode: mode,
                        requestedModelID: modelID,
                        userInputAnswers: userInputAnswers,
                        sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                        requiresSensitiveAnswerRedaction: requiresSensitiveAnswerRedaction,
                        hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt,
                        hideInternalOutcomeReminder: hideInternalOutcomeReminder,
                        deferMissingOutcomeStatus: true,
                        statusBeforeSubmission: statusBeforeSubmission,
                        onTurnStarting: onTurnStarting,
                        onUpdate: onUpdate,
                        onUserInput: onUserInput
                    )
                    let hasPendingUserInput = (try? self.transcripts.read(taskID).pendingUserInputRequest) != nil
                    for reminderNumber in 1...2 where self.lastReportedTurnOutcomeByTaskID[taskID] == nil && !hasPendingUserInput {
                        let reminder = """
                        \(Self.privateOutcomeReminderMarker)

                        StationAI's previous request finished without reporting a task outcome. Do not repeat or change the completed work. If all requested work is finished and no user decision is needed, explicitly run the StationAI CLI task outcome command for this task with `completed`. If you need the user to answer or make a decision before work can continue, explicitly report `waiting-response`. This is reminder \(reminderNumber) of 2; report the outcome now.
                        """
                        do {
                            _ = try await self.sendReserved(
                                taskID: taskID,
                                text: reminder,
                                imageDataURLs: [],
                                mode: mode,
                                requestedModelID: modelID,
                                userInputAnswers: [:],
                                sensitiveUserInputAnswerValues: [],
                                hideSensitiveRecoveryPrompt: true,
                                hideInternalOutcomeReminder: true,
                                deferMissingOutcomeStatus: true,
                                statusBeforeSubmission: nil,
                                onTurnStarting: nil,
                                onUpdate: onUpdate,
                                onUserInput: onUserInput
                            )
                        } catch {
                            // A failed private reminder must not fail the original user turn;
                            // the second explicit request still needs to be attempted.
                        }
                    }
                    if self.lastReportedTurnOutcomeByTaskID[taskID] == nil && !hasPendingUserInput {
                        _ = try await self.tasks.setLifecycleStatus(taskID, to: .waitingResponse)
                    }
                    self.lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    return result
                } catch {
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    throw error
                }
            }
        } catch {
            if retainQueuedMessagesOnFailure, let threadID = try? tasks.taskModel(taskID).activeConversationID {
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
        mode: ConversationMode,
        modelID: String?,
        onlyMessageID: UUID? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) async {
        let threadID: String
        do {
            guard let value = try tasks.taskModel(taskID).activeConversationID else { return }
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
                    if let itemID = item.asyncQuestionItemID {
                        try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: itemID)
                    }
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

    // MARK: - Transcript recording

    /// Appends or updates a visible element of the current Claude turn. Writes
    /// are incremental so a crash mid-turn keeps everything already shown.
    private func recordClaudeMessage(taskID: UUID, turnID: String? = nil, modelID: String? = nil, _ message: ConversationMessage) {
        do {
            try transcripts.mutate(taskID) { transcript in
                guard let index = turnID.flatMap({ id in transcript.turns.lastIndex { $0.id == id } }) ?? transcript.turns.indices.last else { return }
                var message = message
                message.turnID = transcript.turns[index].id
                message.provider = .claude
                message.modelID = message.modelID ?? modelID
                if let existing = transcript.turns[index].messages.firstIndex(where: { $0.id == message.id }) {
                    transcript.turns[index].messages[existing] = message
                } else {
                    transcript.turns[index].messages.append(message)
                }
            }
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            StationAIDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    private func recordClaudeActivity(taskID: UUID, turnID: String, _ activity: ConversationActivity) {
        do {
            try transcripts.mutate(taskID) { transcript in
                // A background Agent/Task call can still be running (or get a terminal
                // notification) after the turn that launched it ends, and after a
                // restart its new turn has no in-memory record of the launch at all.
                // Resolve by the provider's durable backgroundTaskID first, wherever in
                // the transcript that activity actually lives, before falling back to
                // an id match scoped to this turn.
                if let backgroundTaskID = activity.backgroundTaskID {
                    for turnIndex in transcript.turns.indices {
                        guard let existingIndex = transcript.turns[turnIndex].activities.firstIndex(where: {
                            $0.backgroundTaskID == backgroundTaskID
                        }) else { continue }
                        let existing = transcript.turns[turnIndex].activities[existingIndex]
                        let updatedActivity = ConversationActivity(
                            id: existing.id, title: existing.title,
                            detail: activity.detail.isEmpty ? existing.detail : activity.detail,
                            status: activity.status,
                            childThreadID: existing.childThreadID, agentPath: existing.agentPath, model: existing.model,
                            reasoningEffort: existing.reasoningEffort, toolKind: existing.toolKind,
                            server: existing.server, tool: existing.tool,
                            durationMs: activity.durationMs ?? existing.durationMs, startedAt: existing.startedAt,
                            isContextCompaction: existing.isContextCompaction, turnID: existing.turnID,
                            timelineOrder: existing.timelineOrder, backgroundTaskID: existing.backgroundTaskID,
                            backgroundTaskSummary: activity.backgroundTaskSummary ?? existing.backgroundTaskSummary
                        )
                        transcript.turns[turnIndex].activities[existingIndex] = updatedActivity
                        let reportTurnIndex = transcript.turns.lastIndex(where: { $0.id == turnID }) ?? turnIndex
                        let reportTurnID = transcript.turns[reportTurnIndex].id
                        Self.upsertClaudeBackgroundAgentReport(
                            activity: updatedActivity,
                            transcript: &transcript,
                            turnID: reportTurnID
                        )
                        return
                    }
                }
                guard let index = transcript.turns.lastIndex(where: { $0.id == turnID }) else { return }
                var activity = activity
                activity.turnID = turnID
                if let existing = transcript.turns[index].activities.firstIndex(where: { $0.id == activity.id }) {
                    transcript.turns[index].activities[existing] = activity
                } else {
                    transcript.turns[index].activities.append(activity)
                }
                let targetTurnID = transcript.turns[index].id
                Self.upsertClaudeBackgroundAgentReport(activity: activity, transcript: &transcript, turnID: targetTurnID)
            }
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            StationAIDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Claude reports a background agent's result on its task notification,
    /// outside the parent assistant response. Persist that report as a normal
    /// assistant message so it is visible in the conversation and available to
    /// later turns, matching Codex's parent-thread agent message behavior.
    private static func upsertClaudeBackgroundAgentReport(
        activity: ConversationActivity,
        transcript: inout ConversationTranscript,
        turnID: String
    ) {
        guard activity.backgroundTaskID != nil,
              activity.status == "completed",
              let summary = activity.backgroundTaskSummary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let messageID = "claude-background-agent-result-\(activity.id)"
        guard let targetTurnIndex = transcript.turns.firstIndex(where: { $0.id == turnID }) else { return }
        let report = ConversationMessage(
            id: messageID,
            role: .assistant,
            text: summary,
            phase: "subagent_report",
            turnID: turnID,
            provider: .claude
        )
        for index in transcript.turns.indices {
            transcript.turns[index].messages.removeAll { $0.id == messageID }
        }
        transcript.turns[targetTurnIndex].messages.append(report)
    }

    /// Records the accepted turn before its first events can be queried by another XPC call.
    private func recordCodexTurnStarted(taskID: UUID, segmentID: String, turnID: String, modelID: String) {
        do {
            try transcripts.mutate(taskID) { transcript in
                guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                if !transcript.segments[index].codexTurnIDs.contains(turnID) {
                    transcript.segments[index].codexTurnIDs.append(turnID)
                }
                transcript.segments[index].codexTurnModelIDs[turnID] = modelID
            }
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            StationAIDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Assigns Codex turns that ran during a segment to it, so a mixed transcript
    /// keeps them in order after later switches.
    private func claimCodexTurns(taskID: UUID, segmentID: String, _ messages: [ConversationMessage]) {
        let turnIDs = Self.orderedTurnIDs(messages)
        do {
            try transcripts.mutate(taskID) { transcript in
                guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                let claimed = Set(transcript.segments.flatMap(\.codexTurnIDs))
                let newTurnIDs = turnIDs.filter { !claimed.contains($0) }
                transcript.segments[index].codexTurnIDs += newTurnIDs
            }
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            StationAIDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Makes the task's provider the current segment and returns it with the
    /// handoff context its first prompt still needs, if any.
    private func prepareSegment(task: BoardTask) async throws -> (segmentID: String, handoff: String?)? {
        let provider = task.conversationProvider
        var transcript = try transcripts.read(task.id)
        if transcript.segments.last?.provider != provider || transcript.segments.isEmpty {
            transcript = try transcripts.mutate(task.id) { transcript in
                if transcript.segments.last?.provider != provider || transcript.segments.isEmpty {
                    let isInitialExistingCodex = transcript.segments.isEmpty && provider == .codex && task.codexThreadID != nil
                    let isFirst = transcript.segments.isEmpty && task.codexThreadID == nil
                    transcript.segments.append(.init(id: UUID().uuidString, provider: provider, startedAt: .now, handoffDelivered: isFirst || isInitialExistingCodex))
                }
                return transcript
            }
        }
        guard let segment = transcript.segments.last else { return nil }
        guard !segment.handoffDelivered else { return (segment.id, nil) }
        let history = try await history(taskID: task.id)
        let current = transcript.segments.count - 1
        let previousOwnSegment = transcript.segments[..<current].lastIndex { $0.provider == provider }
        let unseenStart = previousOwnSegment.map { index in
            // Everything after this provider's last message is new to it.
            let ownTurnIDs = Set(transcript.turns(in: transcript.segments[index]).map(\.id) + transcript.segments[index].codexTurnIDs)
            return (history.messages.lastIndex { $0.turnID.map(ownTurnIDs.contains) == true } ?? -1) + 1
        } ?? 0
        let unseen = history.messages.dropFirst(unseenStart).filter {
            $0.provider != provider && !Self.isPrivateOutcomeReminderPrompt($0.text)
                && $0.text != Self.privateOutcomeReminderResponsePlaceholder
        }
        return (segment.id, ConversationHandoff.context(for: provider, messages: Array(unseen)))
    }

    private func sendReserved(
        taskID: UUID,
        text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        requestedModelID: String?,
        userInputAnswers: [String: [String]],
        sensitiveUserInputAnswerValues: [String],
        requiresSensitiveAnswerRedaction: Bool = false,
        hideSensitiveRecoveryPrompt: Bool,
        hideInternalOutcomeReminder: Bool,
        deferMissingOutcomeStatus: Bool,
        statusBeforeSubmission: TaskStatus?,
        onTurnStarting: (() -> Void)?,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) async throws -> ConversationHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedText = hideSensitiveRecoveryPrompt
            ? Self.privatePromptPlaceholder(for: normalizedText)
            : Self.redactingSensitiveText(normalizedText, values: sensitiveUserInputAnswerValues)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        var task = try tasks.taskModel(taskID)
        let provider = task.conversationProvider
        let client = clients.client(for: provider)
        let modelID = requestedModelID ?? provider.defaultModelID
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        guard task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task for follow-up work.")
        }
        let availableRoots = task.workspaceRootPaths.compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
        let validationWorkspace = try ConversationWorkspaceContext(roots: availableRoots)
        let effort = ConversationEffort(rawValue: task.conversationEffort) ?? .medium
        try await client.validateEffort(effort, modelID: modelID, workspace: validationWorkspace)
        try tasks.prepareConversationTurnOutcome(taskID)
        defer { tasks.clearConversationTurnOutcome(taskID) }
        var persistedThreadID = task.activeConversationID
        StationAIDiagnostics.recordAndFlush("conversation.send.started", fields: client.diagnosticFields(forThread: persistedThreadID ?? "", [
            "taskID": taskID.uuidString,
            "threadID": task.activeConversationID ?? "new",
            "taskStatus": task.status.rawValue,
            "mode": mode.rawValue
        ]))
        defer {
            if let threadID = persistedThreadID {
                client.clearTurnStarting(threadID: threadID)
            }
        }
        // A task with explicit workspace roots is self-contained and may be
        // sent through CLI/XPC before the UI has initialized the global
        // default-parent setting. Rootless tasks still require that setting.
        let repositoryRoot = try (task.workspaceRootPaths
            .compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
            .first ?? settingsManager.requireRepositoryRootFolder())
        let shouldGenerateTitle = !hideInternalOutcomeReminder
            && !normalizedText.isEmpty
            && ["Untitled task", "Generating title…"].contains(task.title)
        // A caller that already saved the submitted prompt (the composer does,
        // so it survives navigation) supplies the status it replaced.
        let priorStatus = statusBeforeSubmission ?? task.status
        let priorStatusMessage = task.statusMessage
        if !hideInternalOutcomeReminder {
            _ = try await tasks.savePrompt(taskID, prompt: persistedText, status: .inProgress, submitted: true)
        }
        let resolveTitleBeforeWorktree: Bool
        let workspace: ConversationWorkspaceContext
        let titleGeneration: Task<Void, Never>?
        var resolvedWorktreeTitle: String? = ["Untitled task", "Generating title…"].contains(task.title)
            ? nil
            : task.title
        do {
            // Resolve the first submitted prompt's title before preparing any
            // repositories. The app's model context can lag repository changes
            // made through the bridge, so using this snapshot to detect an auto
            // branch can otherwise allocate "untitled-task" before the generated
            // title arrives.
            let titleMustPrecedeAutoWorktree = task.repositoryWorktrees.contains {
                $0.isPending && $0.branch == "auto"
            }
            resolveTitleBeforeWorktree = shouldGenerateTitle && titleMustPrecedeAutoWorktree
            if resolveTitleBeforeWorktree {
                let reserved = try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: task.title,
                    title: "Generating title…"
                )
                if reserved != nil {
                    let titleRoots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    let titleWorkspace = try ConversationWorkspaceContext(roots: titleRoots)
                    resolvedWorktreeTitle = try await generateAndApplyTitle(
                        taskID: taskID,
                        prompt: persistedText,
                        workspace: titleWorkspace,
                        clients: clients.helperClients(preferring: provider)
                    )
                }
                task = try tasks.taskModel(taskID)
                if ["Untitled task", "Generating title…"].contains(task.title) {
                    throw BridgeCommandError(
                        code: "invalid_transition",
                        message: "The task title changed while it was being prepared. Try sending again."
                    )
                }
                resolvedWorktreeTitle = task.title
            }
            task = try await tasks.prepareRepositoryWorktrees(
                taskID,
                fallbackPrompt: hideInternalOutcomeReminder ? (task.savedPrompt ?? persistedText) : persistedText,
                resolvedTitle: resolvedWorktreeTitle ?? persistedText
            )
            if !hideInternalOutcomeReminder, !normalizedText.isEmpty {
                _ = try await tasks.savePrompt(taskID, prompt: persistedText, status: .inProgress, submitted: true)
            }
            let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            workspace = try ConversationWorkspaceContext(roots: roots)
            _ = try await tasks.clearProgressReport(taskID)
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
                    let titleClients = clients.helperClients(preferring: provider)
                    titleGeneration = Task { @MainActor in
                        do {
                            _ = try await self.generateAndApplyTitle(
                                taskID: taskID,
                                prompt: persistedText,
                                workspace: workspace,
                                clients: titleClients
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
        } catch {
            // No turn started: a rejected branch claim, title race, or missing
            // root must not leave the task In Progress. The prompt stays saved
            // as a draft.
            _ = try? await tasks.setLifecycleStatus(taskID, to: priorStatus, message: priorStatusMessage)
            throw error
        }
        let started = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
        onUpdate(ConversationUpdate(type: "started", taskStatus: started.status))
        var phase = "thread-start"
        let approvalNotice = "\(provider.displayName) requested an approval. StationAI denied it because approval prompts are disabled."
        do {
            // Read the visible history for the handoff before this provider gets a
            // new native thread: Codex can't list a thread that has no turns yet.
            phase = "transcript-segment"
            let segment = try await prepareSegment(task: try tasks.taskModel(taskID))
            let sessionRecoveryContext = provider == .claude
                ? ConversationHandoff.context(for: .claude, messages: try await history(taskID: taskID).messages)
                : nil
            phase = "thread-start"
            let threadID: String
            if let existing = task.activeConversationID {
                threadID = existing
            } else {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: TaskThreadDeveloperInstructions.make(
                        taskID: taskID,
                        repositories: task.repositoryWorktrees,
                        contextFolders: task.contextFolderPaths,
                        repositoryRootPath: repositoryRoot.path
                    )
                )
                phase = "thread-persistence"
                _ = try await tasks.persistConversationID(taskID, provider: provider, id: threadID)
                persistedThreadID = threadID
            }
            let claudeTurnID = provider == .claude ? UUID().uuidString.lowercased() : nil
            if let claudeTurnID, let segment {
                try transcripts.mutate(taskID) { transcript in
                    if hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty {
                        transcript.sensitiveTurnIDs = Array(Set(transcript.sensitiveTurnIDs ?? []).union([claudeTurnID])).sorted()
                        // Claude messages are persisted locally from sanitized
                        // callbacks, so the prompt is already safe to retain.
                        transcript.pendingSensitiveUserInputRedaction = false
                    }
                    transcript.turns.append(.init(id: claudeTurnID, segmentID: segment.segmentID, messages: [ConversationMessage(
                        id: "\(claudeTurnID)-user", role: .user, text: persistedText, imageDataURLs: imageDataURLs,
                        turnID: claudeTurnID, provider: .claude, modelID: modelID
                    )]))
                }
            }
            var finalMessageCount = 0
            var leakedOutcome: String?
            var pendingQuestionLifecycleRevision: Int?
            if onTurnStarting != nil {
                client.markTurnStarting(threadID: threadID)
                onTurnStarting?()
            }
            phase = "\(provider.rawValue)-turn"
            try tasks.activateConversationTurnOutcome(taskID)
            try await client.sendMessage(
                ConversationHandoff.prompt(normalizedText, context: segment?.handoff),
                imageDataURLs: imageDataURLs,
                mode: mode,
                modelID: modelID,
                effort: effort,
                threadID: threadID,
                workspace: workspace,
                sessionRecoveryContext: sessionRecoveryContext,
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: repositoryRoot.path
                ),
                onDelta: { delta in
                    guard !hideSensitiveRecoveryPrompt, !hideInternalOutcomeReminder else { return }
                    onUpdate(ConversationUpdate(type: "text_delta", text: delta))
                },
                onFinalMessage: { answer in
                    let split = LeakedTurnOutcome.split(answer)
                    if split.taskID == taskID { leakedOutcome = split.outcome }
                    guard !hideInternalOutcomeReminder else { return }
                    let message = Self.redactingSensitiveText(split.text, values: sensitiveUserInputAnswerValues)
                    // An answer that was only the echo still replaces the streamed text.
                    if let claudeTurnID, !message.isEmpty {
                        finalMessageCount += 1
                        self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, ConversationMessage(
                            id: "\(claudeTurnID)-final-\(finalMessageCount)", role: .assistant, text: message, phase: "final_answer"
                        ))
                    }
                    onUpdate(ConversationUpdate(type: "assistant_final", text: message))
                },
                onActivity: { activity in
                    guard !hideSensitiveRecoveryPrompt, !hideInternalOutcomeReminder else { return }
                    if let claudeTurnID { self.recordClaudeActivity(taskID: taskID, turnID: claudeTurnID, activity) }
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
                onDiff: { diff in
                    guard !hideSensitiveRecoveryPrompt, !hideInternalOutcomeReminder else { return }
                    onUpdate(ConversationUpdate(type: "diff", diff: diff.unifiedDiff))
                },
                onHistory: { history in
                    if provider == .codex, let segment { self.claimCodexTurns(taskID: taskID, segmentID: segment.segmentID, history.messages) }
                    var history = history
                    let matchedPrivateRecoveryTurnIDs = Set(history.messages.filter { message in
                        guard message.role == .user else { return false }
                        let containsPrivatePrompt = hideSensitiveRecoveryPrompt
                            && Self.isPrivateTaskPrompt(message.text)
                            && !Self.isPrivateOutcomeReminderPrompt(message.text)
                        let containsSecretAnswer = sensitiveUserInputAnswerValues.contains {
                            !$0.isEmpty && message.text.contains($0)
                        }
                        return containsPrivatePrompt || containsSecretAnswer
                    }.compactMap(\.turnID))
                    let privateOutcomeReminderTurnIDs = Set(history.messages.filter {
                        $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text)
                    }.compactMap(\.turnID))
                    let previousTranscript = try? self.transcripts.read(taskID)
                    let previouslyPrivateTurnIDs = Set(previousTranscript?.sensitiveCodexTurnIDs ?? [])
                    let previouslySecretRecoveryTurnIDs = Set(previousTranscript?.sensitiveCodexSecretTurnIDs ?? [])
                    let currentSecretRecoveryTurnIDs = Set(history.messages.filter { message in
                        guard message.role == .user else { return false }
                        return sensitiveUserInputAnswerValues.contains { !$0.isEmpty && message.text.contains($0) }
                    }.compactMap(\.turnID))
                    let privateSecretRecoveryTurnIDs = previouslySecretRecoveryTurnIDs.union(currentSecretRecoveryTurnIDs)
                    let previouslyPrivateReminderTurnIDs = Set((previousTranscript?.sensitiveCodexTurnMessages ?? [:]).compactMap { turnID, messages in
                        messages.contains { $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text) } ? turnID : nil
                    })
                    let allPrivateTurnIDs = matchedPrivateRecoveryTurnIDs
                        .union(previouslyPrivateTurnIDs)
                        .union(privateOutcomeReminderTurnIDs)
                    let allPrivateReminderTurnIDs = privateOutcomeReminderTurnIDs.union(previouslyPrivateReminderTurnIDs)
                    if !matchedPrivateRecoveryTurnIDs.isEmpty, previousTranscript != nil {
                        do {
                            var safeCodexMessages: [String: [ConversationMessage]] = [:]
                            if provider == .codex {
                                for turnID in matchedPrivateRecoveryTurnIDs {
                                    safeCodexMessages[turnID] = history.messages
                                        .filter { $0.turnID == turnID }
                                        .map { message -> ConversationMessage in
                                            var safe = Self.redactingSensitiveMessages(
                                                [message], turnIDs: matchedPrivateRecoveryTurnIDs, values: sensitiveUserInputAnswerValues
                                            )[0]
                                            if message.role == .user {
                                                safe.text = Self.privatePromptPlaceholder(for: message.text)
                                                safe.asyncQuestions = nil
                                            } else {
                                                let redactedText = Self.redactingSensitiveText(message.text, values: sensitiveUserInputAnswerValues)
                                                let stillContainsSecret = sensitiveUserInputAnswerValues.contains {
                                                    !$0.isEmpty && redactedText.contains($0)
                                                }
                                                safe.text = privateSecretRecoveryTurnIDs.contains(turnID) || stillContainsSecret
                                                    ? "[Response to private answer hidden]"
                                                    : redactedText
                                                safe.asyncQuestions = nil
                                            }
                                            return safe
                                        }
                                }
                            }
                            try self.transcripts.mutate(taskID) { transcript in
                                transcript.sensitiveTurnIDs = Array(Set(transcript.sensitiveTurnIDs ?? []).union(matchedPrivateRecoveryTurnIDs)).sorted()
                                if provider == .codex {
                                    transcript.sensitiveCodexTurnIDs = Array(Set(transcript.sensitiveCodexTurnIDs ?? []).union(matchedPrivateRecoveryTurnIDs)).sorted()
                                    transcript.sensitiveCodexSecretTurnIDs = Array(Set(transcript.sensitiveCodexSecretTurnIDs ?? []).union(currentSecretRecoveryTurnIDs)).sorted()
                                    var storedMessages = transcript.sensitiveCodexTurnMessages ?? [:]
                                    storedMessages.merge(safeCodexMessages) { _, new in new }
                                    transcript.sensitiveCodexTurnMessages = storedMessages
                                }
                                transcript.pendingSensitiveUserInputRedaction = false
                            }
                        } catch {
                            // Keep the pending marker so later reads redact conservatively.
                        }
                    }
                    let currentTranscript = try? self.transcripts.read(taskID)
                    let safeMessages = history.messages.filter { message in
                        guard let turnID = message.turnID else { return true }
                        return !privateOutcomeReminderTurnIDs.contains(turnID)
                    }.map { message -> ConversationMessage in
                        if let turnID = message.turnID, allPrivateTurnIDs.contains(turnID) {
                            var privateMessage = message
                            privateMessage.text = message.role == .user
                                ? Self.privatePromptPlaceholder(for: message.text)
                                : (allPrivateReminderTurnIDs.contains(turnID)
                                    ? Self.privateOutcomeReminderResponsePlaceholder
                                    : "[Response to private answer hidden]")
                            privateMessage.asyncQuestions = nil
                            return privateMessage
                        }
                        if hideSensitiveRecoveryPrompt,
                           message.role == .user,
                           Self.isPrivateTaskPrompt(message.text) {
                            var privatePrompt = message
                            privatePrompt.text = Self.privatePromptPlaceholder(for: message.text)
                            privatePrompt.asyncQuestions = nil
                            return privatePrompt
                        }
                        return Self.redactingSensitiveMessages(
                            [message], turnIDs: [], values: sensitiveUserInputAnswerValues,
                            redactAllMessages: currentTranscript?.pendingSensitiveUserInputRedaction == true
                        )[0]
                    }
                    let hideProviderDetails = hideSensitiveRecoveryPrompt || hideInternalOutcomeReminder
                        || currentTranscript?.pendingSensitiveUserInputRedaction == true
                    let modelIDs = currentTranscript?.segments.reduce(into: [String: String]()) { result, segment in
                        result.merge(segment.codexTurnModelIDs) { existing, _ in existing }
                    } ?? [:]
                    let attributedMessages = safeMessages.map { message -> ConversationMessage in
                        var message = message
                        if provider == .codex {
                            message.provider = message.provider ?? .codex
                            if message.modelID == nil, let turnID = message.turnID { message.modelID = modelIDs[turnID] }
                        }
                        return message
                    }
                    history = ConversationHistory(
                        messages: attributedMessages,
                        activities: hideProviderDetails
                            ? []
                            : history.activities.filter { activity in
                                activity.turnID.map { !allPrivateTurnIDs.contains($0) } ?? true
                            },
                        diff: hideProviderDetails ? nil : history.diff,
                        answeredAsyncQuestionIDs: (try? self.tasks.answeredAsyncQuestionIDs(taskID: taskID)) ?? [],
                        pendingUserInputRequest: history.pendingUserInputRequest,
                        providerBoundaries: history.providerBoundaries
                    )
                    onUpdate(ConversationUpdate(type: "history", history: history))
                },
                onActionRequest: {
                    onUpdate(ConversationUpdate(type: "action_notice", message: approvalNotice))
                },
                onUserInput: { request async in
                    if hideInternalOutcomeReminder {
                        client.rejectUserInput(
                            requestID: request.id,
                            threadID: request.threadID,
                            message: "This is a private StationAI outcome reminder. Do not ask the user here; report `waiting-response` if you need an answer, or `completed` if the work is finished."
                        )
                        return
                    }
                    do {
                        try self.persistPendingUserInputRequest(request, taskID: taskID)
                    } catch {
                        client.rejectUserInput(requestID: request.id, threadID: request.threadID, message: "StationAI couldn't save this question for recovery. Please try again.")
                        onUpdate(ConversationUpdate(type: "action_notice", message: "Couldn't save the pending question. The provider turn was stopped so the question isn't lost."))
                        return
                    }
                    // A blocking provider question pauses the conversation until
                    // the user answers. Reflect that pause on the board even
                    // though the provider turn remains reserved in the background.
                    let lifecycle = request.isBlocking
                        ? try? await self.tasks.transitionLifecycleStatus(taskID, from: .inProgress, to: .waitingResponse)
                        : nil
                    if let revision = lifecycle ?? nil {
                        pendingQuestionLifecycleRevision = revision
                    }
                    let status = try? await self.tasks.clearProgressReport(taskID)
                    onUpdate(ConversationUpdate(
                        type: "user_input",
                        userInputRequest: request,
                        taskStatus: lifecycle != nil ? TaskStatus.waitingResponse.rawValue : status?.status
                    ))
                    if !userInputAnswers.isEmpty {
                        let answersAccepted = client.answerUserInput(requestID: request.id, threadID: request.threadID, answers: userInputAnswers)
                        if !answersAccepted {
                            onUpdate(ConversationUpdate(type: "action_notice", message: "The supplied answers didn't match \(provider.displayName)'s questions."))
                        } else {
                            try? self.clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
                            if request.isBlocking,
                               let resumed = try? await self.tasks.resumeWaitingResponseAfterUserInput(taskID) {
                                onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed.status))
                            }
                        }
                    }
                    await onUserInput(request)
                },
                onSteerMessage: { message, images in
                    guard !hideInternalOutcomeReminder else { return }
                    if claudeTurnID != nil {
                        self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, ConversationMessage(
                            id: UUID().uuidString.lowercased(), role: .user, text: message, imageDataURLs: images
                        ))
                    }
                    onUpdate(ConversationUpdate(type: "steered_message", message: message, imageDataURLs: images))
                },
                onProgressMessage: { message in
                    guard !hideInternalOutcomeReminder else { return }
                    var safeMessage = message
                    safeMessage.text = Self.redactingSensitiveText(message.text, values: sensitiveUserInputAnswerValues)
                    safeMessage.asyncQuestions = message.asyncQuestions?.map { question in
                        ConversationAsyncQuestion(
                            title: Self.redactingSensitiveText(question.title, values: sensitiveUserInputAnswerValues),
                            options: question.options?.map { Self.redactingSensitiveText($0, values: sensitiveUserInputAnswerValues) }
                        )
                    }
                    if let claudeTurnID {
                        self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, safeMessage)
                    }
                    onUpdate(ConversationUpdate(
                        type: "assistant_progress",
                        text: safeMessage.text,
                        itemID: safeMessage.id,
                        phase: safeMessage.phase,
                        asyncQuestions: safeMessage.asyncQuestions
                    ))
                },
                onTurnStarted: { turnID in
                    if provider == .codex, let segment {
                        self.recordCodexTurnStarted(taskID: taskID, segmentID: segment.segmentID, turnID: turnID, modelID: modelID)
                    }
                },
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt
            )
            if hideSensitiveRecoveryPrompt,
               try transcripts.read(taskID).pendingSensitiveUserInputRedaction == true {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "StationAI couldn't safely record the private answer for conversation history. The question remains available to retry."
                )
            }
            if let segment, segment.handoff != nil || provider == .claude {
                try transcripts.mutate(taskID) { transcript in
                    guard let index = transcript.segments.firstIndex(where: { $0.id == segment.segmentID }) else { return }
                    transcript.segments[index].handoffDelivered = true
                }
            }
            for (activityID, durationMs) in persistedThreadID.map({ client.lastTurnActivityDurations(threadID: $0) }) ?? [:] {
                try await tasks.recordConversationActivityDuration(
                    taskID: taskID,
                    activityID: activityID,
                    durationMs: durationMs
                )
            }
            phase = "worktree-finalization"
            phase = "review-status-persistence"
            let reportedOutcome = try await tasks.finishConversationTurnOutcome(taskID) ?? leakedOutcome
            lastReportedTurnOutcomeByTaskID[taskID] = reportedOutcome
            if reportedOutcome == nil, deferMissingOutcomeStatus, let revision = pendingQuestionLifecycleRevision,
               let stillPending = try? transcripts.read(taskID).pendingUserInputRequest {
                // The turn completed without reporting an outcome while a structured
                // question it raised is still unanswered. Undo the immediate
                // waiting-response flip so the outcome reminder loop — not a stray
                // unanswered question — decides this task's fate, and downgrade the
                // saved request so reopening the conversation doesn't re-force it.
                _ = try? await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: revision)
                if stillPending.isBlocking {
                    try? transcripts.mutate(taskID) { transcript in
                        guard transcript.pendingUserInputRequest?.id == stillPending.id else { return }
                        transcript.pendingUserInputRequest = ConversationUserInputRequest(
                            id: stillPending.id,
                            threadID: stillPending.threadID,
                            questions: stillPending.questions,
                            isBlocking: false,
                            mode: stillPending.mode
                        )
                    }
                }
            } else if reportedOutcome != nil || !deferMissingOutcomeStatus {
                let finalStatus: TaskStatus = reportedOutcome == "completed" ? .review : .waitingResponse
                _ = try await tasks.setLifecycleStatus(taskID, to: finalStatus)
            }
        } catch {
            await titleGeneration?.value
            for (activityID, durationMs) in persistedThreadID.map({ client.lastTurnActivityDurations(threadID: $0) }) ?? [:] {
                try? await tasks.recordConversationActivityDuration(
                    taskID: taskID,
                    activityID: activityID,
                    durationMs: durationMs
                )
            }
            let hideInternalReminderDetails = hideSensitiveRecoveryPrompt || hideInternalOutcomeReminder
            var fields = hideInternalReminderDetails
                ? ["error": "Private conversation recovery turn failed."]
                : StationAIDiagnostics.errorFields(
                    error,
                    redacting: [task.title, task.savedPrompt ?? ""] + sensitiveUserInputAnswerValues
                )
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = persistedThreadID ?? ""
            fields["provider"] = provider.rawValue
            fields["phase"] = phase
            fields["storePath"] = StationAIDiagnostics.storeURL.path
            fields.merge(client.diagnosticFields(forThread: persistedThreadID ?? "", [:])) { _, new in new }
            let shutdownMessage = "StationAI closed while this turn was running. Your conversation is saved; review it and send a follow-up to continue."
            let shouldKeepResumable = client.isPreparingForApplicationTermination
            let wasUserInterrupted = persistedThreadID.map { client.wasLastTurnInterrupted(threadID: $0) } ?? false
            let shouldKeepWaiting = shouldKeepResumable || wasUserInterrupted
            let safeFailureMessage = hideSensitiveRecoveryPrompt || hideInternalOutcomeReminder
                ? (hideInternalOutcomeReminder
                    ? "The private outcome reminder could not be completed."
                    : "The private answer could not be applied. Please answer the question again.")
                : Self.redactingSensitiveText(error.localizedDescription, values: sensitiveUserInputAnswerValues)
            let pendingQuestion = try? transcripts.read(taskID).pendingUserInputRequest
            let hasPendingBlockingQuestion = pendingQuestion?.isBlocking == true
            // A saved non-blocking question stays answerable after the provider
            // exits, exactly as when the task is reconciled on open.
            let hasPendingNonBlockingQuestion = pendingQuestion != nil && !hasPendingBlockingQuestion
            let failureStatus: TaskStatus
            if hasPendingBlockingQuestion || shouldKeepWaiting {
                failureStatus = .waitingResponse
            } else if hasPendingNonBlockingQuestion || hideSensitiveRecoveryPrompt || hideInternalOutcomeReminder {
                failureStatus = .inProgress
            } else {
                failureStatus = .blocked
            }
            _ = try? await tasks.setLifecycleStatus(
                taskID,
                to: failureStatus,
                message: shouldKeepResumable
                    ? shutdownMessage
                    : (wasUserInterrupted ? nil : (hasPendingBlockingQuestion ? "Waiting for your saved question to be answered." : (hasPendingNonBlockingQuestion ? "A saved question is available for your response." : safeFailureMessage)))
            )
            StationAIDiagnostics.record("conversation.send.failed", fields: fields)
            if hideSensitiveRecoveryPrompt || hideInternalOutcomeReminder || !sensitiveUserInputAnswerValues.isEmpty {
                throw BridgeCommandError(code: "operation_failed", message: safeFailureMessage)
            }
            throw error
        }
        await titleGeneration?.value
        let finalHistory = try await history(
            taskID: taskID,
            onActionRequest: {
            onUpdate(ConversationUpdate(type: "action_notice", message: approvalNotice))
            },
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues
        )
        onUpdate(ConversationUpdate(type: "completed", history: finalHistory))
        return finalHistory
    }

    private func generateAndApplyTitle(
        taskID: UUID,
        prompt: String,
        workspace: ConversationWorkspaceContext,
        clients titleClients: [ConversationProviderClient]
    ) async throws -> String {
        let result = await ConversationTitleGenerator(clients: titleClients)
            .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
        let generated = result?.title
        let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let resolvedTitle = generated.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let titleSource = result?.provider.rawValue ?? "prompt-fallback"
        let latest: BoardTask
        do {
            latest = try tasks.taskModel(taskID)
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            StationAIDiagnostics.record("task.title_apply.skipped", fields: fields.merging(["reason": "task_unavailable"]) { _, new in new })
            return fallback
        }
        guard latest.title == "Generating title…" else {
            StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "title_changed",
                "currentTitleState": StationAITaskTitleDiagnostics.state(of: latest.title),
                "titleSource": titleSource
            ])
            return ["Generating title…", "Untitled task"].contains(latest.title)
                ? resolvedTitle
                : latest.title
        }
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
                return currentTitle
            }
            StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                "taskID": taskID.uuidString,
                "titleSource": titleSource,
                "fallbackWordCount": generated == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
            ])
            return resolvedTitle
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
                    return currentTitle
                }
                StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": taskID.uuidString,
                    "titleSource": "prompt-fallback",
                    "fallbackWordCount": String(fallback.split(whereSeparator: \.isWhitespace).count)
                ])
                return fallback
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

    private static let privateRecoveryPromptMarker = "Continue this conversation by applying the user's answer to the pending question"
    private static let privateOutcomeReminderMarker = "StationAI internal outcome reminder:"
    private static let privateOutcomeReminderPlaceholder = "[StationAI private outcome reminder hidden]"
    private static let privateOutcomeReminderResponsePlaceholder = "[StationAI private outcome response hidden]"

    private static func isPrivateTaskPrompt(_ text: String) -> Bool {
        text.contains(privateRecoveryPromptMarker) || text.contains(privateOutcomeReminderMarker)
    }

    private static func privatePromptPlaceholder(for text: String) -> String {
        isPrivateOutcomeReminderPrompt(text)
            ? privateOutcomeReminderPlaceholder
            : "[Private answer sent after restart]"
    }

    private static func isPrivateOutcomeReminderPrompt(_ text: String) -> Bool {
        text.contains(privateOutcomeReminderMarker) || text.contains(privateOutcomeReminderPlaceholder)
    }

    private static func redactingSensitiveText(_ text: String, values: [String]) -> String {
        values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { result, value in
            result.replacingOccurrences(of: value, with: "[redacted secret answer]")
        }
    }

    private static func sensitiveCodexTurnIDs(_ transcript: ConversationTranscript) -> Set<String> {
        let codexTurnIDs = Set(transcript.segments.filter { $0.provider == .codex }.flatMap(\.codexTurnIDs))
        return Set(transcript.sensitiveCodexTurnIDs ?? [])
            .union(Set(transcript.sensitiveTurnIDs ?? []).intersection(codexTurnIDs))
    }

    private static func codexMessagesForDisplay(
        _ messages: [ConversationMessage],
        transcript: ConversationTranscript
    ) -> [ConversationMessage] {
        let privateTurnIDs = sensitiveCodexTurnIDs(transcript)
        let privateReminderTurnIDs = Set(messages.filter {
            $0.role == .user && isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID))
        let safeMessagesByTurn = transcript.sensitiveCodexTurnMessages ?? [:]
        var emittedSafeTurnIDs = Set<String>()
        var visible: [ConversationMessage] = []
        for message in messages {
            if message.turnID.map(privateReminderTurnIDs.contains) == true { continue }
            guard let turnID = message.turnID, privateTurnIDs.contains(turnID) else {
                visible.append(message)
                continue
            }
            if let safeMessages = safeMessagesByTurn[turnID] {
                if emittedSafeTurnIDs.insert(turnID).inserted {
                    visible.append(contentsOf: safeMessages)
                }
            } else {
                var placeholder = message
                placeholder.text = message.role == .user
                    ? privatePromptPlaceholder(for: message.text)
                    : (privateReminderTurnIDs.contains(turnID)
                        ? privateOutcomeReminderResponsePlaceholder
                        : "[Response to private answer hidden]")
                placeholder.asyncQuestions = nil
                visible.append(placeholder)
            }
        }
        return visible
    }

    private static func shouldHideCodexDiff(_ transcript: ConversationTranscript, codex: ConversationHistory?) -> Bool {
        if transcript.pendingSensitiveUserInputRedaction == true { return true }
        let latestCodexTurnID = transcript.segments.last(where: { $0.provider == .codex })?.codexTurnIDs.last
            ?? codex?.messages.reversed().compactMap(\.turnID).first
        guard let latestCodexTurnID else {
            return !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        }
        return sensitiveCodexTurnIDs(transcript).contains(latestCodexTurnID)
    }

    private static func redactingSensitiveMessages(
        _ messages: [ConversationMessage],
        turnIDs: Set<String>,
        values: [String] = [],
        redactAllMessages: Bool = false
    ) -> [ConversationMessage] {
        let privateReminderTurnIDs = Set(messages.filter {
            $0.role == .user && isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID))
        return messages.map { message in
            let matchesTurn = message.turnID.map(turnIDs.contains) ?? false
            let matchesValue = values.contains { !$0.isEmpty && message.text.contains($0) }
            var redacted = message
            if redactAllMessages || matchesTurn {
                redacted.text = message.role == .user
                    ? privatePromptPlaceholder(for: message.text)
                    : (message.turnID.map { privateReminderTurnIDs.contains($0) } == true
                        ? privateOutcomeReminderResponsePlaceholder
                        : "[Response to private answer hidden]")
                redacted.asyncQuestions = nil
            } else if matchesValue {
                redacted.text = Self.redactingSensitiveText(message.text, values: values)
            }
            if !redactAllMessages, !matchesTurn, let questions = message.asyncQuestions {
                redacted.asyncQuestions = questions.map { question in
                    ConversationAsyncQuestion(
                        title: Self.redactingSensitiveText(question.title, values: values),
                        options: question.options?.map { Self.redactingSensitiveText($0, values: values) }
                    )
                }
            }
            return redacted
        }
    }

    static func isValidModelID(_ value: String) -> Bool {
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

        // Turn state lives in this process's memory, so reading it needs no store.
        if request.command == "conversation.runtime" || request.command == "conversation.runtime.subscribe" {
            let runtimeScope: String?
            #if DEBUG
            runtimeScope = request.dataDirectory
            #else
            runtimeScope = nil
            #endif
            do {
                let result: BridgeValue
                if request.command == "conversation.runtime" {
                    result = try Self.value(ConversationRuntimeSnapshot.current(dataDirectory: runtimeScope))
                } else {
                    // Streams the daemon's turn state to a window until it disconnects.
                    for await snapshot in ConversationRuntimeSnapshot.changes(dataDirectory: runtimeScope) {
                        if Task.isCancelled { break }
                        eventHandler(BridgeEvent(requestID: request.id, type: "runtime_state", payload: try Self.value(snapshot)))
                    }
                    result = .object(["subscribed": .boolean(false)])
                }
                await StationAIDiagnostics.endBatch()
                return .success(request, result: result)
            } catch {
                await StationAIDiagnostics.endBatch()
                return .failure(request, code: "operation_failed", message: error.localizedDescription)
            }
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
            let workspaces = WorkspaceManager(taskManager: taskManager, settingsManager: settings)
            try await workspaces.reconcileDeferredRepositoryRemovals()

            let codexExecutable = request.arguments["__codexExecutable"]?.string
            let claudeExecutable = request.arguments["__claudeExecutable"]?.string
            // A window's requests run goals against one long-lived Codex client
            // that observes goal turns, as the window's own client used to.
            let guiRuntime = request.arguments["__guiRuntime"]?.bool == true
            // The caller's Codex home, so a window and the CLI read the same threads.
            let callerCodexHome = request.arguments["__codexHome"]?.string
            func conversationClients(codexHome: String? = nil, goalFeatureEnabled: Bool = false) -> ConversationClients {
                ConversationClients(
                    codex: CodexAppServerClient.sharedClient(executableOverride: codexExecutable, codexHomeOverride: codexHome ?? callerCodexHome, goalFeatureEnabled: goalFeatureEnabled, goalRuntimeEnabled: guiRuntime, dataDirectory: dataDirectory),
                    claude: ClaudeCodeClient.sharedPrimaryClient(executableOverride: claudeExecutable, dataDirectory: dataDirectory)
                )
            }

            let result: BridgeValue
            switch request.command {
            case "status":
                result = .object([
                    "service": .string("StationAI"),
                    "bridgeVersion": .integer(BridgeContract.currentVersion),
                    "processID": .integer(Int(ProcessInfo.processInfo.processIdentifier))
                ])
            case "board.list", "task.list":
                result = try Self.value(["tasks": taskManager.list()])
            case "archive.search":
                let conversations = ConversationManager(tasks: taskManager, clients: ConversationClients(codex: CodexAppServerClient(), claude: ClaudeCodeClient()), settingsManager: settings)
                result = try Self.value(await conversations.searchArchive(
                    query: request.requiredString("query"),
                    codexHomePath: request.arguments["codexHome"]?.string ?? callerCodexHome
                ))
            case "task.create":
                let title = try request.requiredString("title")
                let roots = try request.requiredStrings("roots")
                let repositories = try request.repositorySpecs("repositories")
                let provider = try request.arguments["provider"]?.string.map(ConversationProvider.parse) ?? settings.defaultConversationProvider
                result = try Self.value(await taskManager.create(title: title, repositories: repositories, contextFolders: roots, provider: provider))
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
                    clients: conversationClients(),
                    settingsManager: settings
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
                    clients: conversationClients()
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
            case "task.repository.replace":
                result = try Self.value(await workspaces.replaceRepositories(
                    request.requiredStrings("repositoryPaths"),
                    on: request.requiredUUID("taskID")
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
                result = try Self.value(await workspaces.removeRepository(
                    request.requiredString("repositoryPath"),
                    from: request.requiredUUID("taskID")
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
                try await taskManager.delete(request.requiredUUID("taskID"), diagnostics: conversationClients().codex.diagnosticFields())
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
            case "task.changes.mark-viewed":
                try await workspaces.markViewed(
                    for: request.requiredUUID("taskID"),
                    repository: request.requiredString("repository"),
                    path: request.requiredString("path")
                )
                result = .object(["viewed": .boolean(true)])
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
            case "workspace.repositories.list":
                let root = try settings.requireRepositoryRootFolder()
                let repositories = try await workspaces.suggestedRepositories(parentPath: root.path)
                result = .object([
                    "root": .string(root.path),
                    "repositories": .array(repositories.map(BridgeValue.string))
                ])
            case "settings.get":
                result = .object([
                    "defaultParentFolder": settings.defaultParentFolderPath.isEmpty ? .null : .string(settings.defaultParentFolderPath),
                    "defaultParentAvailable": .boolean(settings.defaultParentFolderURL != nil),
                    "lastSelectedRepositories": .array(settings.lastSelectedRepositories.map(BridgeValue.string)),
                    "appearance": .string(settings.appearance),
                    "defaultProvider": .string(settings.defaultConversationProvider.rawValue)
                ])
            case "settings.set-default-provider":
                try settings.setDefaultConversationProvider(request.requiredString("provider"))
                result = .object(["defaultProvider": .string(settings.defaultConversationProvider.rawValue)])
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
                let clients = conversationClients()
                _ = try await taskManager.reconcileLifecycleStatusOnOpen(taskID, clients: clients)
                let conversations = ConversationManager(tasks: taskManager, clients: clients, settingsManager: settings)
                result = try Self.value(await conversations.history(taskID: taskID, onActionRequest: {
                    eventHandler(BridgeEvent(requestID: request.id, type: "action_request", payload: .object([:])))
                }))
            case "conversation.present-image":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(await conversations.publishImage(
                    taskID: request.requiredUUID("taskID"),
                    path: request.requiredString("path"),
                    caption: request.arguments["caption"]?.string ?? ""
                ))
            case "conversation.models":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["models": .array(try await conversations.models(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.effort.get":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["effort": .string(try conversations.effort(taskID: request.requiredUUID("taskID")).rawValue)])
            case "conversation.effort.set":
                let taskID = try request.requiredUUID("taskID")
                guard let effort = ConversationEffort(rawValue: try request.requiredString("effort")) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Effort must be one of: low, medium, high, xhigh.")
                }
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let task = try await conversations.setEffort(taskID: taskID, effort: effort)
                result = try Self.value(task)
            case "conversation.model.get":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["modelID": try conversations.modelID(taskID: request.requiredUUID("taskID")).map(BridgeValue.string) ?? .null])
            case "conversation.model.set":
                let taskID = try request.requiredUUID("taskID")
                let modelID = try request.requiredString("modelID")
                guard ConversationManager.isValidModelID(modelID) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, numbers, periods, underscores, or hyphens.")
                }
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                try conversations.setModelID(taskID: taskID, modelID: modelID)
                result = .object(["modelID": .string(modelID)])
            case "conversation.models.cached":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["models": .array(try conversations.cachedModels(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.stop":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["interrupted": .boolean(try await conversations.interrupt(taskID: request.requiredUUID("taskID")))])
            case "conversation.provider.get":
                let task = try taskManager.taskModel(request.requiredUUID("taskID"))
                result = .object([
                    "provider": .string(task.conversationProvider.rawValue),
                    "supportsGoals": .boolean(task.conversationProvider.supportsGoals)
                ])
            case "conversation.provider.set":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = try Self.value(await conversations.setProvider(
                    taskID: request.requiredUUID("taskID"),
                    provider: ConversationProvider.parse(request.requiredString("provider"))
                ))
            case "conversation.provider.capabilities":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .array(try await conversations.providerCapabilities(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })
            case "conversation.goal":
                var clients = conversationClients(goalFeatureEnabled: !guiRuntime)
                // Codex allows one writer per thread: use the client that already has it open.
                var ownsClient = !guiRuntime
                if let threadID = try? taskManager.taskModel(request.requiredUUID("taskID")).codexThreadID,
                   let owner = CodexAppServerClient.sharedClient(loading: threadID, compatibleWith: clients.codex), owner !== clients.codex {
                    clients = ConversationClients(codex: owner, claude: clients.claude)
                    ownsClient = false
                }
                defer { if ownsClient { clients.codex.shutdown() } }
                let conversations = ConversationManager(tasks: taskManager, clients: clients, settingsManager: settings, preferences: preferences)
                let goal = try await conversations.goal(
                    taskID: request.requiredUUID("taskID"),
                    objective: request.arguments["objective"]?.string,
                    action: request.arguments["action"]?.string ?? "get",
                    observeRuntime: guiRuntime && request.arguments["observe"]?.bool == true
                )
                if let goal { result = try Self.value(goal) } else { result = .null }
            case "conversation.queue", "conversation.queue.list", "conversation.queue.retry", "conversation.queue.remove", "conversation.queue.steer", "conversation.steer":
                let taskID = try request.requiredUUID("taskID")
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                switch request.command {
                case "conversation.queue": result = try Self.value(conversations.queueMessage(taskID: taskID, text: request.requiredString("message")))
                case "conversation.queue.list": result = .array(try conversations.queuedMessages(taskID: taskID).map { try Self.value($0) })
                case "conversation.queue.retry":
                    let retried = try await conversations.retryQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"), onUpdate: { update in
                        if let payload = try? Self.value(update) {
                            eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                        }
                    })
                    result = .object(["retried": .boolean(retried)])
                case "conversation.queue.remove":
                    try conversations.removeQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"))
                    result = .object(["removed": .boolean(true)])
                case "conversation.queue.steer":
                    let steered = try await conversations.steerQueuedMessage(taskID: taskID, messageID: request.requiredUUID("messageID"))
                    result = .object(["text": .string(steered.message), "accepted": .boolean(true), "queued": .boolean(!steered.accepted)])
                default:
                    let accepted = try await conversations.steer(taskID: taskID, text: request.arguments["message"]?.string ?? "", imageDataURLs: request.arguments["images"]?.strings ?? [])
                    if request.arguments["queueIfMissed"]?.bool == false {
                        result = .object(["accepted": .boolean(accepted), "queued": .boolean(false)])
                    } else if accepted {
                        result = .object(["accepted": .boolean(true), "queued": .boolean(false)])
                    } else {
                        _ = try await conversations.queueMissedSteer(taskID: taskID, text: request.arguments["message"]?.string ?? "", imageDataURLs: request.arguments["images"]?.strings ?? [])
                        result = .object(["accepted": .boolean(true), "queued": .boolean(true)])
                    }
                }
            case "conversation.answer_async":
                let taskID = try request.requiredUUID("taskID")
                let itemID = try request.requiredString("itemID")
                let answers = request.arguments["answers"]?.strings ?? []
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let history = try await conversations.history(taskID: taskID)
                guard let question = history.messages.first(where: { $0.id == itemID && $0.asyncQuestions != nil }) else {
                    throw BridgeCommandError(code: "not_found", message: "That question is not in this conversation.")
                }
                let answer = try await conversations.answerAsyncQuestion(taskID: taskID, question: question, answers: answers)
                var answered: [String: BridgeValue] = ["text": .string(answer.text), "queued": .boolean(answer.queued)]
                if let history = answer.history { answered["history"] = try Self.value(history) }
                result = .object(answered)
            case "conversation.repair_user_input":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try await Self.value(conversations.repairPendingUserInput(
                    taskID: request.requiredUUID("taskID"), sourceTaskID: request.requiredUUID("sourceTaskID")
                ))
            case "conversation.answer_user_input":
                let taskID = try request.requiredUUID("taskID")
                let requestID = try request.requiredString("requestID")
                let answers = try request.optionalStringArrays("answers")
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let accepted = try await conversations.answerUserInput(
                    taskID: taskID,
                    requestID: requestID,
                    answers: answers,
                    modelID: request.arguments["model"]?.string,
                    onUpdate: { update in
                        if let payload = try? Self.value(update) {
                            eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                        }
                    }
                )
                result = .object(["accepted": .boolean(accepted)])
            case "conversation.subagent_history":
                let activity: ConversationActivity = try Self.decode(request.arguments["activity"])
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(await conversations.subagentHistory(taskID: request.requiredUUID("taskID"), activity: activity))
            case "conversation.answered_async":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["itemIDs": .array(try conversations.answeredAsyncQuestionIDs(taskID: request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "conversation.queue.missed_steer":
                let taskID = try request.requiredUUID("taskID")
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(try await conversations.queueMissedSteer(
                    taskID: taskID,
                    text: request.arguments["message"]?.string ?? "",
                    imageDataURLs: request.arguments["images"]?.strings ?? [],
                    onUpdate: { update in
                        if let payload = try? Self.value(update) {
                            eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                        }
                    }
                ))
            case "task.reconcile":
                result = try Self.value(await taskManager.reconcileLifecycleStatusOnOpen(request.requiredUUID("taskID"), clients: conversationClients()))
            case "task.title.generate":
                let taskID = try request.requiredUUID("taskID")
                let prompt = try request.requiredString("prompt")
                let task = try taskManager.taskModel(taskID)
                guard let workspace = try? ConversationWorkspaceContext(roots: task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }) else {
                    StationAIDiagnostics.record("task.title_generation.failed", fields: [
                        "taskID": taskID.uuidString,
                        "phase": "workspace-resolution",
                        "reason": "workspace_unavailable"
                    ])
                    result = .null
                    break
                }
                let generated = await ConversationTitleGenerator(clients: conversationClients().helperClients(preferring: task.conversationProvider))
                    .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
                result = generated.map { .object(["title": .string($0.title), "provider": .string($0.provider.rawValue)]) } ?? .null
            case "conversation.send":
                let taskID = try request.requiredUUID("taskID")
                let message = request.arguments["message"]?.string ?? ""
                let modeValue = request.arguments["mode"]?.string ?? ConversationMode.code.rawValue
                guard let mode = ConversationMode(rawValue: modeValue) else {
                    throw BridgeCommandError(
                        code: "invalid_argument",
                        message: "Unknown conversation mode '\(modeValue)'. Valid modes: default, plan."
                    )
                }
                let modelID = request.arguments["model"]?.string
                let answers = try request.optionalStringArrays("answers")
                let imageDataURLs = request.arguments["images"]?.strings ?? []
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let statusBeforeSubmission = request.arguments["statusBeforeSubmission"]?.string.flatMap(TaskStatus.init(rawValue:))
                let reportsTurnStarting = request.arguments["reportTurnStarting"]?.bool == true
                let history = try await conversations.send(taskID: taskID, text: message, imageDataURLs: imageDataURLs, mode: mode, modelID: modelID, userInputAnswers: answers, statusBeforeSubmission: statusBeforeSubmission, onTurnStarting: reportsTurnStarting ? {
                    eventHandler(BridgeEvent(requestID: request.id, type: "turn_starting", payload: .object([:])))
                } : nil, onUpdate: { update in
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
            fields.merge(StationAIDiagnostics.errorFields(error, includeUserInfoDetails: true)) { _, new in new }
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

    private static func decode<T: Decodable>(_ value: BridgeValue?) throws -> T {
        guard let value else {
            throw BridgeCommandError(code: "invalid_argument", message: "A required argument is missing.")
        }
        return try value.decoded(T.self)
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

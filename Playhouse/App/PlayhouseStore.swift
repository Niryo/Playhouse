import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

@MainActor
enum PlayhouseStore {
    private static var lifecycleGateHeld = false
    private static var lifecycleGateWaiters: [CheckedContinuation<Void, Never>] = []

    static func storeURL(dataDirectory: String? = nil) throws -> URL {
        if let dataDirectory {
            if !PlayhouseAppIdentity.isTestBundle {
                let requested = URL(fileURLWithPath: dataDirectory, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL
                let expected = try PlayhouseAppIdentity.defaultDataDirectory()
                    .resolvingSymlinksInPath().standardizedFileURL
                guard requested == expected else {
                    throw StoreSchemaRepairError("This Playhouse worktree app cannot open another app’s task store.")
                }
            }
            return URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("Playhouse-v2.store")
        }
        let supportDirectory = try PlayhouseAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent("Playhouse-v2.store")
    }

    static func makeContainer(dataDirectory: String? = nil) throws -> ModelContainer {
        try validateTestDataDirectory(dataDirectory)
        let schema = Schema([BoardTask.self, StandaloneChat.self])
        let storeURL: URL
        do {
            storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        } catch {
            // A rejected linked-app override must not send diagnostics to that foreign store directory.
            let profileDirectory = PlayhouseAppIdentity.worktreeKey != nil
                ? try? PlayhouseAppIdentity.defaultDataDirectory().path : nil
            PlayhouseDiagnostics.useDataDirectory(profileDirectory)
            PlayhouseDiagnostics.recordAndFlush(
                "persistence.store.path.failed",
                fields: PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)
                    .merging(["phase": "resolve-store-path"]) { _, new in new }
            )
            throw error
        }
        PlayhouseDiagnostics.useDataDirectory(dataDirectory)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacyStoreURL = storeURL.deletingLastPathComponent().appendingPathComponent("Playhouse.store")
            if FileManager.default.fileExists(atPath: legacyStoreURL.path) || (try? storeNeedsPendingPromptColumn(storeURL)) == true {
                PlayhouseDiagnostics.recordAndFlush("persistence.store.schema_migration.waiting_for_schema_lock", fields: [
                    "storePath": storeURL.path
                ])
            }
            return try withSchemaRepairLock(at: storeURL) {
                try importLegacyStoreIfNeeded(at: storeURL)
                // A legacy store can have both an old model hash and a missing column.
                // Opening SwiftData first can fail before the table repair is reached.
                let configuration = ModelConfiguration(
                    "Playhouse",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                if try storeNeedsPendingPromptColumn(storeURL) {
                    // Hold the write lock through SwiftData's model metadata update.
                    let waitStartedAt = Date()
                    PlayhouseDiagnostics.recordAndFlush("persistence.store.schema_migration.waiting_for_write_lock", fields: [
                        "storePath": storeURL.path
                    ])
                    return try withStoreWriteLock(at: storeURL) {
                        PlayhouseDiagnostics.recordAndFlush("persistence.store.schema_migration.write_lock_acquired", fields: [
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
                            PlayhouseDiagnostics.record("persistence.store.schema_repaired", fields: [
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
            var fields = PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)
            fields.merge(PlayhouseDiagnostics.storeContextFields(for: storeURL)) { _, new in new }
            fields.merge(Self.schemaProbeFields(at: storeURL)) { _, new in new }
            fields["phase"] = "model-container-open"
            PlayhouseDiagnostics.recordAndFlush("persistence.store.open.failed", fields: fields)
            throw error
        }
    }

    private static func validateTestDataDirectory(_ dataDirectory: String?) throws {
        #if DEBUG
        guard PlayhouseAppIdentity.isTestBundle else { return }
        guard let dataDirectory, !dataDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreSchemaRepairError("A Playhouse test bundle requires an isolated data directory.")
        }
        let path = URL(fileURLWithPath: dataDirectory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let allowedRoots = [FileManager.default.temporaryDirectory.path, "/tmp"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path }
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw StoreSchemaRepairError("A Playhouse test bundle requires an isolated temporary data directory.")
        }
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: dataDirectory, isDirectory: true)
                .appendingPathComponent("Playhouse-v2.store" + suffix)
            var metadata = stat()
            if Darwin.lstat(candidate.path, &metadata) == 0,
               metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw StoreSchemaRepairError("A Playhouse test bundle cannot open a linked task store.")
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
        let source = destination.deletingLastPathComponent().appendingPathComponent("Playhouse.store")
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
        PlayhouseDiagnostics.recordAndFlush("persistence.store.legacy_imported", fields: [
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
            "Playhouse.store.before-pending-prompt-\(UUID().uuidString).backup"
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

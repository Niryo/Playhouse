import Foundation
import GRDB

@MainActor
package enum PlayhouseStore {
    private static var lifecycleGateHeld = false
    private static var lifecycleGateWaiters: [CheckedContinuation<Void, Never>] = []

    package static let storeFileName = "Playhouse-v3.sqlite"
    /// The SwiftData store this one replaced, and the store that one replaced in turn; the
    /// first found is moved into a new store once, and both are left on disk as backups.
    package static let swiftDataStoreFileNames = ["Playhouse-v2.store", "Playhouse.store"]

    package static func storeURL(dataDirectory: String? = nil) throws -> URL {
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
            return URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent(storeFileName)
        }
        let supportDirectory = try PlayhouseAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent(storeFileName)
    }

    package static func makeContainer(dataDirectory: String? = nil) throws -> PlayhouseModelContainer {
        try validateTestDataDirectory(dataDirectory)
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
            if !FileManager.default.fileExists(atPath: storeURL.path), swiftDataStoreURL(besides: storeURL) != nil {
                PlayhouseDiagnostics.recordAndFlush("persistence.store.swiftdata_migration.waiting_for_schema_lock", fields: [
                    "storePath": storeURL.path
                ])
            }
            if let open = openContainer(at: storeURL) { return open }
            return try withSchemaRepairLock(at: storeURL) {
                try migrateSwiftDataStoreIfNeeded(to: storeURL)
                let container = try PlayhouseModelContainer(storeURL: storeURL)
                openContainers[storeURL.standardizedFileURL.path] = (container, fileNumber(storeURL))
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

    /// One open container per store file for the life of the process (the daemon opens the
    /// store for every request). A file replaced since it was opened gets a new container.
    private static var openContainers: [String: (container: PlayhouseModelContainer, fileNumber: Int?)] = [:]

    private static func openContainer(at storeURL: URL) -> PlayhouseModelContainer? {
        guard let open = openContainers[storeURL.standardizedFileURL.path],
              let current = fileNumber(storeURL), current == open.fileNumber else { return nil }
        return open.container
    }

    private static func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
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
                .appendingPathComponent(storeFileName + suffix)
            if POSIX.isSymbolicLink(candidate.path) {
                throw StoreSchemaRepairError("A Playhouse test bundle cannot open a linked task store.")
            }
        }
        #endif
    }

    /// Probe the task schema only after a persistence failure, so the diagnostic names a missing
    /// table or column rather than only an SQLite error code.
    package static func schemaProbeFields(at storeURL: URL?) -> [String: String] {
        guard let storeURL else { return ["schemaProbeResult": "store-path-unavailable"] }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return ["schemaProbeResult": "store-missing"] }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(0.25)
        func failure(_ result: String, _ error: Error) -> [String: String] {
            var fields = ["schemaProbeResult": result]
            if let error = error as? DatabaseError {
                fields["schemaProbeSQLiteCode"] = String(error.extendedResultCode.rawValue)
                fields["schemaProbeSQLiteMessage"] = String((error.message ?? error.description).prefix(2_048))
            } else {
                fields["schemaProbeSQLiteMessage"] = String(String(describing: error).prefix(2_048))
            }
            return fields
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
        } catch {
            return failure("open-failed", error)
        }
        do {
            // A zero-row query naming every persisted column validates the table and column
            // names without reading task data.
            try queue.read { db in _ = try Row.fetchAll(db, sql: "SELECT \(ModelStoreSchema.columnList(BoardTask.self)) FROM board_tasks LIMIT 0") }
            return ["schemaProbeResult": "ok"]
        } catch {
            return failure("prepare-failed", error)
        }
    }

    private static func withSchemaRepairLock<T>(at storeURL: URL, _ body: () throws -> T) throws -> T {
        let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("store-schema-repair.lock")
        return try POSIX.withExclusiveFileLock(at: lockURL.path, body)
    }

    /// The SwiftData store to move, when this data directory has one.
    private static func swiftDataStoreURL(besides storeURL: URL) -> URL? {
        swiftDataStoreFileNames
            .map { storeURL.deletingLastPathComponent().appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves the tasks and chats of a SwiftData store into the new store, once: only while the
    /// new store doesn't exist yet, and never reading the SwiftData file again afterwards.
    private static func migrateSwiftDataStoreIfNeeded(to storeURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: storeURL.path), let source = swiftDataStoreURL(besides: storeURL) else { return }
        guard POSIX.isRegularFile(source.path) else {
            throw StoreSchemaRepairError("The SwiftData task store must be a regular file.")
        }
        let startedAt = Date()
        let summary = try SwiftDataStoreMigration.migrate(from: source, to: storeURL)
        PlayhouseDiagnostics.recordAndFlush("persistence.store.swiftdata_migrated", fields: [
            "sourcePath": source.path,
            "storePath": storeURL.path,
            "boardTaskCount": String(summary.boardTasks),
            "standaloneChatCount": String(summary.standaloneChats),
            "skippedRowCount": String(summary.skippedRows),
            "durationMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
        ])
    }

    @MainActor
    package static func prepareLifecycle(container: PlayhouseModelContainer, dataDirectory: String? = nil) async throws {
        await Self.acquireLifecycleGate()
        defer { Self.releaseLifecycleGate() }
        let storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        let directory = storeURL.deletingLastPathComponent()
        let marker = directory.appendingPathComponent("task-lifecycle-v2-reset")
        let lockURL = directory.appendingPathComponent("task-lifecycle-v2-reset.lock")
        let lockDescriptor = try await Self.acquireLifecycleLock(at: lockURL)
        defer { _ = POSIX.close(lockDescriptor) }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let context = PlayhouseModelContext(container: container)
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
            let descriptor = POSIX.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw StoreLifecycleLockError(message: "Couldn't open the task-store lifecycle lock (errno \(errno)).")
            }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            while POSIX.fcntl(descriptor, F_SETLK, &lock) != 0 {
                if errno == EACCES || errno == EAGAIN {
                    usleep(50_000)
                    continue
                }
                let code = errno
                _ = POSIX.close(descriptor)
                throw StoreLifecycleLockError(message: "Couldn't acquire the task-store lifecycle lock (errno \(code)).")
            }
            return descriptor
        }.value
    }

    package static func takeLifecycleResetNotice(dataDirectory: String? = nil) -> [String] {
        guard let directory = try? Self.storeURL(dataDirectory: dataDirectory).deletingLastPathComponent() else { return [] }
        let notice = directory.appendingPathComponent("task-lifecycle-v2-notice.json")
        guard let data = try? Data(contentsOf: notice),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: notice)
        return paths
    }
}

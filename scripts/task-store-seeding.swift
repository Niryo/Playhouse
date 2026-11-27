import Foundation
import SQLite3
import notify

// Shared by the test seeders that change a running Playhouse's task store from outside it.
// A write stamps the changed row with the next store revision and posts the store's change
// signal, as the app's own saves do, so a running app and daemon merge it at once.

enum TaskStoreSeedError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

final class TaskStoreSeeding {
    static let fileName = "Playhouse-v3.sqlite"
    private let storeURL: URL
    private var database: OpaquePointer?

    /// Opens the task store of `dataDirectory`, which a Playhouse process must have created.
    init(dataDirectory: URL) throws {
        storeURL = dataDirectory.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw TaskStoreSeedError.unavailable("No task store at \(storeURL.path); open it with Playhouse first.")
        }
        guard sqlite3_open(storeURL.path, &database) == SQLITE_OK else {
            throw TaskStoreSeedError.unavailable("The task store couldn't be opened.")
        }
        sqlite3_busy_timeout(database, 30_000)
    }

    deinit { sqlite3_close(database) }

    /// Runs `body` in one write transaction with the revision its writes are stamped with, then
    /// signals the change.
    func write(_ body: (Int64) throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE store_meta SET value = value + 1 WHERE key = 'revision'")
            let revision = try queryInt("SELECT value FROM store_meta WHERE key = 'revision'")
            try body(revision)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        notify_post("com.playhouse.model-store:" + storeURL.resolvingSymlinksInPath().path)
    }

    func execute(_ sql: String, _ arguments: [Any?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TaskStoreSeedError.unavailable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, arguments)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TaskStoreSeedError.unavailable(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// The text or blob of the first column of the first row, nil when the row or value is missing.
    func queryData(_ sql: String, _ arguments: [Any?] = []) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TaskStoreSeedError.unavailable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, arguments)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func queryInt(_ sql: String, _ arguments: [Any?] = []) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TaskStoreSeedError.unavailable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, arguments)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TaskStoreSeedError.unavailable("No row for \(sql)") }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ statement: OpaquePointer?, _ arguments: [Any?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, transient)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Bool: sqlite3_bind_int64(statement, index, value ? 1 : 0)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }
}

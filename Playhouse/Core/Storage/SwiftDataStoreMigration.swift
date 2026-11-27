import Foundation
import GRDB

/// The one-time move of a SwiftData task store into the GRDB store.
///
/// SwiftData kept tasks in Core Data's SQLite layout: a `ZBOARDTASK` and a `ZSTANDALONECHAT`
/// table whose columns are each property's name upper-cased with a `Z` prefix, UUIDs as 16 raw
/// bytes, dates as seconds since 2001 and `Data` as plain blobs. The move reads a consistent
/// snapshot of that file with plain SQL (no SwiftData), so it works for any schema version a
/// user may still have: a column an older version never had keeps the property's default.
/// The SwiftData file is left untouched as a backup.
package enum SwiftDataStoreMigration {
    package struct Summary: Equatable {
        package var boardTasks = 0
        package var standaloneChats = 0
        package var skippedRows = 0

        package init(boardTasks: Int = 0, standaloneChats: Int = 0, skippedRows: Int = 0) {
            self.boardTasks = boardTasks
            self.standaloneChats = standaloneChats
            self.skippedRows = skippedRows
        }
    }

    /// Writes every task and chat of the SwiftData store at `source` into a new store at
    /// `destination`, which must not exist yet. The new store appears only once complete.
    package static func migrate(from source: URL, to destination: URL) throws -> Summary {
        let directory = destination.deletingLastPathComponent()
        let snapshotURL = directory.appendingPathComponent(".swiftdata-snapshot-\(UUID().uuidString).sqlite")
        let stagingURL = directory.appendingPathComponent(".store-migration-\(UUID().uuidString).sqlite")
        defer {
            for url in [snapshotURL, stagingURL] {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try? FileManager.default.removeItem(atPath: url.path + suffix)
                }
            }
        }
        let copyURL = directory.appendingPathComponent(".swiftdata-copy-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copyURL.path + suffix) }
        }
        let snapshot = try DatabaseQueue(path: snapshotURL.path)
        // A backup reads the committed WAL content too, without writing to the source. SQLite
        // can only open a WAL store read-only while its shared-memory file exists, so without
        // one the files are copied as they are and the copy is read instead.
        var readOnly = Configuration()
        readOnly.readonly = true
        readOnly.busyMode = .timeout(5)
        do {
            try DatabaseQueue(path: source.path, configuration: readOnly).backup(to: snapshot)
        } catch {
            for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
                try FileManager.default.copyItem(atPath: source.path + suffix, toPath: copyURL.path + suffix)
            }
            try DatabaseQueue(path: copyURL.path).backup(to: snapshot)
        }
        guard try snapshot.read({ try String.fetchOne($0, sql: "PRAGMA quick_check") }) == "ok" else {
            throw StoreSchemaRepairError("The SwiftData task store failed its integrity check.")
        }

        var summary = Summary()
        let staging = try DatabaseQueue(path: stagingURL.path)
        try staging.write { db in
            try ModelStoreSchema.migrate(db)
            let revision = try ModelStoreSchema.nextRevision(db)
            try snapshot.read { legacy in
                summary.boardTasks = try copy(BoardTask.self, table: "ZBOARDTASK", from: legacy, to: db, revision: revision, skipped: &summary.skippedRows)
                summary.standaloneChats = try copy(StandaloneChat.self, table: "ZSTANDALONECHAT", from: legacy, to: db, revision: revision, skipped: &summary.skippedRows)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO store_meta (key, value) VALUES ('migratedFromSwiftData', ?)",
                arguments: [source.lastPathComponent]
            )
        }
        try staging.close()
        try FileManager.default.moveItem(at: stagingURL, to: destination)
        return summary
    }

    private static func copy<Model: PersistentModel>(
        _ model: Model.Type, table: String, from legacy: Database, to db: Database, revision: Int64, skipped: inout Int
    ) throws -> Int {
        guard try legacy.tableExists(table) else { return 0 }
        let columns = Set(try Row.fetchAll(legacy, sql: "PRAGMA table_info(\(table))").map { ($0["name"] as String).uppercased() })
        var copied = 0
        for row in try Row.fetchAll(legacy, sql: "SELECT * FROM \(table) ORDER BY Z_PK") {
            guard let id = UUID.fromCoreDataColumn(row["ZID"]) else {
                skipped += 1
                continue
            }
            let object = Model(storedID: id)
            for property in Model.persistedProperties where property.name != "id" {
                guard let column = property.coreDataColumns.first(where: columns.contains) else { continue }
                property.applyCoreData(object, row[column])
            }
            let values = Model.persistedProperties.map { $0.read(object) }
            let names = Model.persistedProperties.map(\.name.quotedDatabaseIdentifier).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
            try db.execute(
                sql: "INSERT OR IGNORE INTO \(Model.tableName.quotedDatabaseIdentifier) (revision, \(names)) VALUES (?, \(placeholders))",
                arguments: StatementArguments([revision.databaseValue] + values)
            )
            // SwiftData didn't keep ids unique; a second row with an id already copied is skipped.
            if db.changesCount == 0 { skipped += 1 } else { copied += 1 }
        }
        return copied
    }
}

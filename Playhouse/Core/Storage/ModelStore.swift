import Foundation
import Observation
import GRDB
#if canImport(notify)
import notify
#endif

// The task store: board tasks and standalone chats in one SQLite database, shared by the app,
// the bridge daemon and the CLI's daemon on demand. It replaces SwiftData with the same
// working model the code was written against: a context hands out one live, observable object
// per stored row, edits stay pending until `save()`, and a save writes only the properties that
// changed, so two processes editing different properties of one task never undo each other.
// Every write stamps its rows with a store-wide revision and posts a change signal; contexts in
// every process then re-read just the rows newer than the revision they last saw.

/// A model class whose stored properties are rows of one table.
package protocol PersistentModel: AnyObject, Identifiable {
    static var tableName: String { get }
    /// Every persisted property, `id` first. Adding a property here adds its column to existing
    /// stores the next time they open.
    static var persistedProperties: [PersistedProperty<Self>] { get }
    /// A blank object for a stored row; the store applies the row's columns to it.
    init(storedID: UUID)
    var id: UUID { get }
    var persistenceState: ModelPersistenceState { get }
}

/// Where an object stands relative to its store, kept out of observation.
package final class ModelPersistenceState {
    /// The column values last read from or written to the store; a property whose current
    /// value differs is a pending change.
    package var snapshot: [String: DatabaseValue] = [:]
    package var isDeleted = false
    package init() {}
}

/// How a Swift value is stored in a column.
package protocol ModelColumnValue: Equatable {
    static var columnType: String { get }
    var columnValue: DatabaseValue { get }
    /// Nil when the stored value can't be read as this type; the property keeps its value.
    static func fromColumn(_ value: DatabaseValue) -> Self?
}

extension String: ModelColumnValue {
    package static var columnType: String { "TEXT" }
    package var columnValue: DatabaseValue { databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> String? { String.fromDatabaseValue(value) }
}

extension Int: ModelColumnValue {
    package static var columnType: String { "INTEGER" }
    package var columnValue: DatabaseValue { databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> Int? { Int.fromDatabaseValue(value) }
}

extension Double: ModelColumnValue {
    package static var columnType: String { "REAL" }
    package var columnValue: DatabaseValue { databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> Double? { Double.fromDatabaseValue(value) }
}

extension Bool: ModelColumnValue {
    package static var columnType: String { "INTEGER" }
    package var columnValue: DatabaseValue { databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> Bool? { Bool.fromDatabaseValue(value) }
}

extension Data: ModelColumnValue {
    package static var columnType: String { "BLOB" }
    package var columnValue: DatabaseValue { databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> Data? { Data.fromDatabaseValue(value) }
}

/// Dates are seconds since 2001 as a REAL, which round-trips exactly and is also how Core Data
/// stored them.
extension Date: ModelColumnValue {
    package static var columnType: String { "REAL" }
    package var columnValue: DatabaseValue { timeIntervalSinceReferenceDate.databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> Date? {
        Double.fromDatabaseValue(value).map(Date.init(timeIntervalSinceReferenceDate:))
    }
}

/// UUIDs are stored as their text form.
extension UUID: ModelColumnValue {
    package static var columnType: String { "TEXT" }
    package var columnValue: DatabaseValue { uuidString.databaseValue }
    package static func fromColumn(_ value: DatabaseValue) -> UUID? {
        String.fromDatabaseValue(value).flatMap(UUID.init(uuidString:))
    }
}

extension Optional: ModelColumnValue where Wrapped: ModelColumnValue {
    package static var columnType: String { Wrapped.columnType }
    package var columnValue: DatabaseValue { self?.columnValue ?? .null }
    package static func fromColumn(_ value: DatabaseValue) -> Wrapped?? {
        value.isNull ? .some(nil) : Wrapped.fromColumn(value).map { .some($0) }
    }
}

/// One persisted property: its column and how to read and write it on an object.
package struct PersistedProperty<Model: AnyObject> {
    package let name: String
    package let columnType: String
    package let read: (Model) -> DatabaseValue
    /// Sets the property from a stored value when it differs, so an unchanged value never
    /// notifies observers.
    package let apply: (Model, DatabaseValue) -> Void

    package init<Value: ModelColumnValue>(
        _ name: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Value>
    ) {
        self.name = name
        columnType = Value.columnType
        read = { $0[keyPath: keyPath].columnValue }
        apply = { model, stored in
            guard let value = Value.fromColumn(stored), model[keyPath: keyPath] != value else { return }
            model[keyPath: keyPath] = value
        }
    }
}

/// A condition a fetch matches rows against, evaluated in SQL for stored rows and in memory for
/// objects inserted but not yet saved.
package enum ModelFilter {
    case equals(String, any ModelColumnValue)
    case notEquals(String, any ModelColumnValue)
    case isNotNull(String)
    case isTrue(String)

    fileprivate var sql: (String, StatementArguments) {
        switch self {
        case .equals(let column, let value): ("\(column.quotedDatabaseIdentifier) = ?", [value.columnValue])
        case .notEquals(let column, let value): ("\(column.quotedDatabaseIdentifier) IS NOT ?", [value.columnValue])
        case .isNotNull(let column): ("\(column.quotedDatabaseIdentifier) IS NOT NULL", [])
        case .isTrue(let column): ("\(column.quotedDatabaseIdentifier) = 1", [])
        }
    }

    fileprivate func matches<Model: PersistentModel>(_ model: Model) -> Bool {
        func value(_ column: String) -> DatabaseValue {
            Model.persistedProperties.first { $0.name == column }?.read(model) ?? .null
        }
        switch self {
        case .equals(let column, let expected): return value(column) == expected.columnValue
        case .notEquals(let column, let expected): return value(column) != expected.columnValue
        case .isNotNull(let column): return !value(column).isNull
        case .isTrue(let column): return Bool.fromDatabaseValue(value(column)) == true
        }
    }
}

/// What to fetch: matching rows in an order, optionally one page of them.
package struct ModelFetch<Model: PersistentModel> {
    package var filters: [ModelFilter] = []
    package var sortBy: [(column: String, ascending: Bool)] = []
    package var limit: Int?
    package var offset: Int?

    package init(_ filters: ModelFilter..., sortBy: [(column: String, ascending: Bool)] = [], limit: Int? = nil, offset: Int? = nil) {
        self.filters = filters
        self.sortBy = sortBy
        self.limit = limit
        self.offset = offset
    }
}

package enum ModelStoreError: Error, LocalizedError {
    case unreadableRow(table: String)
    case duplicateInsert(table: String, id: UUID)

    package var errorDescription: String? {
        switch self {
        case .unreadableRow(let table): "A stored \(table) row has no readable ID."
        case .duplicateInsert(let table, let id): "A \(table) row with ID \(id.uuidString) already exists."
        }
    }
}

/// The open task store of one data directory.
package final class PlayhouseModelContainer: @unchecked Sendable {
    package let storeURL: URL
    package let pool: DatabasePool
    private let changeSignal: StoreChangeSignal

    @MainActor private var contexts: [WeakModelContext] = []
    @MainActor package private(set) lazy var mainContext = PlayhouseModelContext(container: self)

    package init(storeURL: URL) throws {
        self.storeURL = storeURL
        var configuration = Configuration()
        // Another process may hold the write lock while it saves a turn's bookkeeping.
        configuration.busyMode = .timeout(30)
        pool = try DatabasePool(path: storeURL.path, configuration: configuration)
        _ = chmod(storeURL.path, 0o600)
        try pool.write { db in try ModelStoreSchema.migrate(db) }
        changeSignal = StoreChangeSignal(name: "com.playhouse.model-store:" + storeURL.resolvingSymlinksInPath().path)
        changeSignal.observe { [weak self] in
            Task { @MainActor in self?.storeDidChange() }
        }
    }

    @MainActor package func register(_ context: PlayhouseModelContext) {
        contexts.removeAll { $0.context == nil }
        contexts.append(WeakModelContext(context: context))
    }

    package func postChange() { changeSignal.post() }

    @MainActor private func storeDidChange() {
        contexts.removeAll { $0.context == nil }
        for entry in contexts { entry.context?.refreshFromStore() }
    }

    package func currentRevision() throws -> Int64 {
        try pool.read { db in try ModelStoreSchema.revision(db) }
    }
}

private struct WeakModelContext {
    weak var context: PlayhouseModelContext?
}

/// A working set of stored objects, like SwiftData's `ModelContext`: each row is one object for
/// as long as anything holds it, edits are pending until `save()`, and stores written by other
/// contexts or processes are merged into unchanged properties as they land.
@MainActor
@Observable
package final class PlayhouseModelContext {
    @ObservationIgnored package let container: PlayhouseModelContainer
    /// Bumped whenever the stored set may have changed (a save, an insert or delete, or a merge
    /// of another writer's rows), so queries reading it run again.
    package private(set) var changeRevision = 0

    /// One object per stored row, kept for the context's life so pending edits are never lost
    /// and every reader of a row sees the same object.
    @ObservationIgnored private var registered: [String: [UUID: any PersistentModel]] = [:]
    @ObservationIgnored private var insertedModels: [any PersistentModel] = []
    @ObservationIgnored private var deletedModels: [any PersistentModel] = []
    @ObservationIgnored private var lastSeenRevision: Int64

    package var storeURL: URL { container.storeURL }

    package init(container: PlayhouseModelContainer) {
        self.container = container
        lastSeenRevision = (try? container.currentRevision()) ?? 0
        container.register(self)
    }

    // MARK: Reading

    /// The stored objects matching `request`, plus inserted ones not yet saved. Objects already
    /// in the context are refreshed from their rows in properties without pending edits.
    package func fetch<Model: PersistentModel>(_ request: ModelFetch<Model> = ModelFetch(), refreshing: Bool = true) throws -> [Model] {
        var clauses: [String] = []
        var arguments = StatementArguments()
        for filter in request.filters {
            let (clause, filterArguments) = filter.sql
            clauses.append(clause)
            arguments += filterArguments
        }
        var sql = "SELECT \(ModelStoreSchema.columnList(Model.self)) FROM \(Model.tableName.quotedDatabaseIdentifier)"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        if !request.sortBy.isEmpty {
            sql += " ORDER BY " + request.sortBy.map { "\($0.column.quotedDatabaseIdentifier) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
        }
        let pending = insertedModels.compactMap { $0 as? Model }.filter { model in request.filters.allSatisfy { $0.matches(model) } }
        // Pending inserts join the stored rows before paging, so page the merged list in memory.
        if pending.isEmpty, let limit = request.limit {
            sql += " LIMIT \(limit)"
            if let offset = request.offset { sql += " OFFSET \(offset)" }
        }
        let rows = try container.pool.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
        var models: [Model] = []
        models.reserveCapacity(rows.count + pending.count)
        for row in rows {
            guard let model = try object(for: row, refreshing: refreshing) as Model?, !model.persistenceState.isDeleted,
                  !deletedModels.contains(where: { $0 === model }) else { continue }
            models.append(model)
        }
        guard !pending.isEmpty else { return models }
        models.append(contentsOf: pending)
        if !request.sortBy.isEmpty {
            models.sort { lhs, rhs in
                for sort in request.sortBy {
                    guard let property = Model.persistedProperties.first(where: { $0.name == sort.column }) else { continue }
                    let order = ModelStoreSchema.compare(property.read(lhs), property.read(rhs))
                    if order != .orderedSame { return sort.ascending ? order == .orderedAscending : order == .orderedDescending }
                }
                return false
            }
        }
        let start = min(request.offset ?? 0, models.count)
        let end = request.limit.map { min(models.count, start + $0) } ?? models.count
        return Array(models[start..<end])
    }

    /// The object for a stored row: the registered one, refreshed, or a new one.
    private func object<Model: PersistentModel>(for row: Row, refreshing: Bool) throws -> Model? {
        guard let id = UUID.fromColumn(row["id"]) else { throw ModelStoreError.unreadableRow(table: Model.tableName) }
        if let existing = registered[Model.tableName]?[id] as? Model {
            if refreshing { merge(row, into: existing) }
            return existing
        }
        let model = Model(storedID: id)
        for property in Model.persistedProperties {
            guard row.hasColumn(property.name) else { continue }
            let value: DatabaseValue = row[property.name]
            property.apply(model, value)
            model.persistenceState.snapshot[property.name] = value
        }
        register(model)
        return model
    }

    /// Applies a stored row to an object, leaving properties with pending edits alone.
    private func merge<Model: PersistentModel>(_ row: Row, into model: Model) {
        for property in Model.persistedProperties {
            guard row.hasColumn(property.name) else { continue }
            let stored: DatabaseValue = row[property.name]
            let snapshot = model.persistenceState.snapshot[property.name]
            guard snapshot != stored else { continue }
            // A pending edit keeps its value and now applies over the newer stored one.
            if snapshot == nil || property.read(model) == snapshot {
                property.apply(model, stored)
            }
            model.persistenceState.snapshot[property.name] = stored
        }
    }

    private func register<Model: PersistentModel>(_ model: Model) {
        registered[Model.tableName, default: [:]][model.id] = model
    }

    // MARK: Changing

    package func insert<Model: PersistentModel>(_ model: Model) {
        guard !insertedModels.contains(where: { $0 === model }) else { return }
        if let index = deletedModels.firstIndex(where: { $0 === model }) {
            deletedModels.remove(at: index)
        } else {
            insertedModels.append(model)
        }
        changeRevision += 1
    }

    package func delete<Model: PersistentModel>(_ model: Model) {
        if let index = insertedModels.firstIndex(where: { $0 === model }) {
            insertedModels.remove(at: index)
        } else if !deletedModels.contains(where: { $0 === model }) {
            deletedModels.append(model)
        }
        changeRevision += 1
    }

    /// Whether anything is waiting to be saved.
    package var hasChanges: Bool {
        !insertedModels.isEmpty || !deletedModels.isEmpty || registeredModels().contains { !changedProperties(of: $0).isEmpty }
    }

    /// Objects with pending edits, inserts or deletes.
    package var changedModelsArray: [any PersistentModel] {
        insertedModels + deletedModels + registeredModels().filter { model in
            !changedProperties(of: model).isEmpty && !deletedModels.contains { $0 === model }
        }
    }

    private func registeredModels() -> [any PersistentModel] {
        registered.values.flatMap { $0.values }.filter { !$0.persistenceState.isDeleted }
    }

    private func changedProperties(of model: any PersistentModel) -> [String: DatabaseValue] {
        func changes<Model: PersistentModel>(_ model: Model) -> [String: DatabaseValue] {
            var result: [String: DatabaseValue] = [:]
            for property in Model.persistedProperties {
                let value = property.read(model)
                if model.persistenceState.snapshot[property.name] != value { result[property.name] = value }
            }
            return result
        }
        return changes(model)
    }

    private func allColumns(of model: any PersistentModel) -> [String: DatabaseValue] {
        func columns<Model: PersistentModel>(_ model: Model) -> [String: DatabaseValue] {
            Dictionary(uniqueKeysWithValues: Model.persistedProperties.map { ($0.name, $0.read(model)) })
        }
        return columns(model)
    }

    private func tableName(of model: any PersistentModel) -> String { type(of: model).tableName }

    /// Writes every pending change in one transaction. On failure nothing is written and the
    /// changes stay pending.
    package func save() throws {
        let inserts = insertedModels.map { ($0, allColumns(of: $0)) }
        let deletes = deletedModels.filter { model in registered[tableName(of: model)]?[model.id] === model }
        let updates = registeredModels()
            .filter { model in !deletedModels.contains { $0 === model } }
            .map { ($0, changedProperties(of: $0)) }
            .filter { !$0.1.isEmpty }
        guard !inserts.isEmpty || !deletes.isEmpty || !updates.isEmpty else {
            insertedModels.removeAll()
            deletedModels.removeAll()
            return
        }
        let revision = try container.pool.write { db -> Int64 in
            let revision = try ModelStoreSchema.nextRevision(db)
            for (model, columns) in inserts {
                let table = tableName(of: model)
                if try Bool.fetchOne(db, sql: "SELECT 1 FROM \(table.quotedDatabaseIdentifier) WHERE id = ?", arguments: [model.id.uuidString]) == true {
                    throw ModelStoreError.duplicateInsert(table: table, id: model.id)
                }
                let names = columns.keys.sorted()
                let sql = "INSERT INTO \(table.quotedDatabaseIdentifier) (revision, \(names.map(\.quotedDatabaseIdentifier).joined(separator: ", "))) VALUES (?, \(Array(repeating: "?", count: names.count).joined(separator: ", ")))"
                try db.execute(sql: sql, arguments: StatementArguments([revision.databaseValue] + names.map { columns[$0]! }))
                try db.execute(sql: "DELETE FROM deleted_models WHERE entity = ? AND id = ?", arguments: [table, model.id.uuidString])
            }
            for (model, columns) in updates {
                let names = columns.keys.sorted()
                let assignments = names.map { "\($0.quotedDatabaseIdentifier) = ?" }.joined(separator: ", ")
                let sql = "UPDATE \(tableName(of: model).quotedDatabaseIdentifier) SET revision = ?, \(assignments) WHERE id = ?"
                try db.execute(sql: sql, arguments: StatementArguments([revision.databaseValue] + names.map { columns[$0]! } + [model.persistenceState.snapshot["id"] ?? model.id.columnValue]))
            }
            for model in deletes {
                let table = tableName(of: model)
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier) WHERE id = ?", arguments: [model.id.uuidString])
                try db.execute(
                    sql: "INSERT INTO deleted_models (entity, id, revision) VALUES (?, ?, ?) ON CONFLICT(entity, id) DO UPDATE SET revision = excluded.revision",
                    arguments: [table, model.id.uuidString, revision]
                )
            }
            return revision
        }
        // With no other writer in between, this context has already seen everything up to its own
        // save, so the change signal it posts to itself doesn't re-read the store.
        if revision == lastSeenRevision + 1 { lastSeenRevision = revision }
        for (model, columns) in inserts {
            model.persistenceState.snapshot = columns
            registerAny(model)
        }
        for (model, columns) in updates {
            for (name, value) in columns { model.persistenceState.snapshot[name] = value }
        }
        for model in deletes {
            model.persistenceState.isDeleted = true
            registered[tableName(of: model)]?[model.id] = nil
        }
        insertedModels.removeAll()
        deletedModels.removeAll()
        changeRevision += 1
        container.postChange()
    }

    private func registerAny(_ model: any PersistentModel) {
        func add<Model: PersistentModel>(_ model: Model) { register(model) }
        add(model)
    }

    /// Merges rows other contexts and processes wrote since this context last looked, and drops
    /// objects they deleted.
    package func refreshFromStore() {
        let since = lastSeenRevision
        let tables = ModelStoreSchema.tables
        guard let (revision, rows, tombstones) = try? container.pool.read({ db -> (Int64, [String: [Row]], [(String, String)]) in
            let revision = try ModelStoreSchema.revision(db)
            guard revision > since else { return (revision, [:], []) }
            var rows: [String: [Row]] = [:]
            for table in tables where registered[table]?.isEmpty == false {
                rows[table] = try Row.fetchAll(db, sql: "SELECT \(ModelStoreSchema.columnList(table)) FROM \(table.quotedDatabaseIdentifier) WHERE revision > ?", arguments: [since])
            }
            let tombstones = try Row.fetchAll(db, sql: "SELECT entity, id FROM deleted_models WHERE revision > ?", arguments: [since])
                .map { ($0["entity"] as String, $0["id"] as String) }
            return (revision, rows, tombstones)
        }) else { return }
        guard revision > since else { return }
        lastSeenRevision = revision
        for (table, tableRows) in rows {
            for row in tableRows {
                guard let id = UUID.fromColumn(row["id"]), let model = registered[table]?[id] else { continue }
                mergeAny(row, into: model)
            }
        }
        for (table, idString) in tombstones {
            guard let id = UUID(uuidString: idString), let model = registered[table]?[id] else { continue }
            model.persistenceState.isDeleted = true
            registered[table]?[id] = nil
        }
        changeRevision += 1
    }

    private func mergeAny(_ row: Row, into model: any PersistentModel) {
        func apply<Model: PersistentModel>(_ model: Model) { merge(row, into: model) }
        apply(model)
    }
}

/// A live list of stored objects for a view, the counterpart of SwiftData's `@Query`: reading
/// `results(in:)` runs its fetch again whenever the context's stored set may have changed.
@MainActor
package final class ModelQuery<Model: PersistentModel> {
    private let request: ModelFetch<Model>
    private var cached: (context: ObjectIdentifier, revision: Int, models: [Model])?

    package init(_ request: ModelFetch<Model>) {
        self.request = request
    }

    package func results(in context: PlayhouseModelContext) -> [Model] {
        let revision = context.changeRevision
        if let cached, cached.context == ObjectIdentifier(context), cached.revision == revision { return cached.models }
        // Registered objects are kept current by saves and merges; reading inside a view
        // update must not also write to them.
        let models = (try? context.fetch(request, refreshing: false)) ?? []
        cached = (ObjectIdentifier(context), revision, models)
        return models
    }
}

package enum ModelStoreSchema {
    package static let tables = [BoardTask.tableName, StandaloneChat.tableName]
    /// Bump when a persisted property is added, so existing stores gain its column. A store
    /// already at this version is used as it is: a column missing from it is an error that
    /// reads report, never something papered over.
    package static let version = 1

    package static func migrate(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 < version else { return }
        try prepare(db)
        try db.execute(sql: "PRAGMA user_version = \(version)")
    }

    /// Every persisted column, named, so a read fails on a store that lacks one.
    package static func columnList<Model: PersistentModel>(_ model: Model.Type) -> String {
        Model.persistedProperties.map(\.name.quotedDatabaseIdentifier).joined(separator: ", ")
    }

    package static func columnList(_ table: String) -> String {
        switch table {
        case BoardTask.tableName: columnList(BoardTask.self)
        case StandaloneChat.tableName: columnList(StandaloneChat.self)
        default: preconditionFailure("\(table) is not a table of the model store.")
        }
    }

    package static func prepare(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS store_meta (key TEXT PRIMARY KEY NOT NULL, value);
            INSERT OR IGNORE INTO store_meta (key, value) VALUES ('revision', 0);
            CREATE TABLE IF NOT EXISTS deleted_models (
                entity TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY (entity, id)
            );
            CREATE INDEX IF NOT EXISTS deleted_models_by_revision ON deleted_models(revision);
            """)
        try prepareTable(BoardTask.self, db)
        try prepareTable(StandaloneChat.self, db)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS board_tasks_by_status ON board_tasks(statusRawValue, createdAt);
            CREATE INDEX IF NOT EXISTS standalone_chats_by_parallel ON standalone_chats(parallelOfChatID);
            """)
    }

    /// Creates the table, then adds a column for any persisted property it lacks.
    package static func prepareTable<Model: PersistentModel>(_ model: Model.Type, _ db: Database) throws {
        let table = Model.tableName.quotedDatabaseIdentifier
        let columns = Model.persistedProperties.filter { $0.name != "id" }
            .map { "\($0.name.quotedDatabaseIdentifier) \($0.columnType)" }
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(table) (
                id TEXT PRIMARY KEY NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0,
                \(columns.joined(separator: ",\n    "))
            );
            CREATE INDEX IF NOT EXISTS \("\(Model.tableName)_by_revision".quotedDatabaseIdentifier) ON \(table)(revision);
            """)
        let existing = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { ($0["name"] as String).lowercased() })
        for property in Model.persistedProperties where !existing.contains(property.name.lowercased()) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(property.name.quotedDatabaseIdentifier) \(property.columnType)")
        }
    }

    package static func revision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT value FROM store_meta WHERE key = 'revision'") ?? 0
    }

    package static func nextRevision(_ db: Database) throws -> Int64 {
        try db.execute(sql: "UPDATE store_meta SET value = value + 1 WHERE key = 'revision'")
        return try revision(db)
    }

    package static func compare(_ lhs: DatabaseValue, _ rhs: DatabaseValue) -> ComparisonResult {
        switch (lhs.storage, rhs.storage) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedAscending
        case (_, .null): return .orderedDescending
        case (.int64(let a), .int64(let b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (.double(let a), .double(let b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (.int64(let a), .double(let b)): return Double(a) == b ? .orderedSame : (Double(a) < b ? .orderedAscending : .orderedDescending)
        case (.double(let a), .int64(let b)): return a == Double(b) ? .orderedSame : (a < Double(b) ? .orderedAscending : .orderedDescending)
        case (.string(let a), .string(let b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        default: return .orderedSame
        }
    }
}

/// The cross-process "the store changed" signal: a Darwin notification named for the store
/// file, delivered to every process with the store open, including the one that posted it.
package final class StoreChangeSignal: @unchecked Sendable {
    private let name: String
    #if canImport(notify)
    private var token: Int32?
    #endif

    package init(name: String) { self.name = name }

    package func observe(_ handler: @escaping @Sendable () -> Void) {
        #if canImport(notify)
        var registered: Int32 = 0
        if notify_register_dispatch(name, &registered, DispatchQueue.main, { _ in handler() }) == NOTIFY_STATUS_OK {
            token = registered
        }
        #endif
    }

    package func post() {
        #if canImport(notify)
        notify_post(name)
        #endif
    }

    deinit {
        #if canImport(notify)
        if let token { notify_cancel(token) }
        #endif
    }
}

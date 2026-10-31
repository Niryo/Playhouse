import Foundation
import SQLite3
import Darwin

/// Persistence and search for the standalone chat feature's "pages": a continuous,
/// repo/worktree-free conversation split into titled segments so the live provider
/// context stays bounded while the full archive remains locally searchable.
///
/// Storage lives in its own SQLite database (separate from the SwiftData task store),
/// mirroring `PlayhouseStore`'s per-worktree data-directory isolation so e2e fixtures
/// and distinct app instances never share chat history.
struct StandaloneChatPage: Codable, Equatable {
    var id: String
    var chatID: String
    var title: String
    var summary: String?
    var createdAt: Date
    var closedAt: Date?
    var provider: String
    var providerSessionID: String?
    var messageCount: Int

    /// The provider session that holds only this page's turns. A page records one session at a
    /// time: switching provider mid-page starts that provider's own fresh session for the page.
    func conversationID(forProvider provider: String) -> String? {
        guard self.provider == provider, let providerSessionID, !providerSessionID.isEmpty else { return nil }
        return providerSessionID
    }
}

struct StandaloneChatMessage: Codable, Equatable {
    var id: String
    var pageID: String
    var turnID: String
    var role: String
    var text: String
    var createdAt: Date
    var timelineOrder: Int
}

struct StandaloneChatPageMatch: Codable, Equatable {
    var page: StandaloneChatPage
    var snippet: String
    var rank: Double
}

struct StandaloneChatPendingFallback: Equatable {
    var pageID: String
    var turnID: String
}

private struct StandaloneChatPageArchive: Codable {
    let formatVersion: Int
    let page: StandaloneChatPage
    let messages: [StandaloneChatMessage]
}

enum StandaloneChatStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open the standalone chat database: \(message)"
        case .queryFailed(let message): "Standalone chat query failed: \(message)"
        case .notFound(let message): message
        }
    }
}

final class StandaloneChatManager {
    static let defaultChatID = "default"
    private static let pageFileProcessLock = NSLock()
    private static let pageFileBackfillLock = NSLock()

    private var database: OpaquePointer?
    private let pageFilesDirectory: URL
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func storeURL(dataDirectory: String? = nil) throws -> URL {
        if let dataDirectory {
            return URL(fileURLWithPath: dataDirectory, isDirectory: true)
                .appendingPathComponent("StandaloneChat-v1.sqlite")
        }
        let supportDirectory = try PlayhouseAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent("StandaloneChat-v1.sqlite")
    }

    init(dataDirectory: String? = nil) throws {
        let url = try Self.storeURL(dataDirectory: dataDirectory)
        pageFilesDirectory = url.deletingLastPathComponent().appendingPathComponent("StandaloneChat-Pages", isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close(handle) }
            throw StandaloneChatStoreError.openFailed(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)
        try migrate()
        try backfillPageFilesIfNeeded()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_pages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT,
            created_at TEXT NOT NULL,
            closed_at TEXT,
            provider TEXT NOT NULL,
            provider_session_id TEXT,
            message_count INTEGER NOT NULL DEFAULT 0
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL REFERENCES chat_pages(id),
            turn_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            timeline_order INTEGER NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS chat_messages_page_idx ON chat_messages(page_id, timeline_order);")
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_meta (
            chat_id TEXT PRIMARY KEY,
            signal_sequence INTEGER NOT NULL DEFAULT 0,
            last_turn_missed_signal INTEGER NOT NULL DEFAULT 0
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_pending_fallback (
            chat_id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL,
            turn_id TEXT NOT NULL
        );
        """)
        try exec("CREATE TABLE IF NOT EXISTS chat_archive_migrations (version INTEGER PRIMARY KEY);")
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chat_pages_fts USING fts5(
            title, summary, content='chat_pages', content_rowid='rowid', tokenize='porter unicode61'
        );
        """)
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chat_messages_fts USING fts5(
            text, content='chat_messages', content_rowid='rowid', tokenize='porter unicode61'
        );
        """)
        for (table, ftsTable, columns) in [
            ("chat_pages", "chat_pages_fts", "title, summary"),
            ("chat_messages", "chat_messages_fts", "text"),
        ] {
            try exec("""
            CREATE TRIGGER IF NOT EXISTS \(table)_ai AFTER INSERT ON \(table) BEGIN
                INSERT INTO \(ftsTable)(rowid, \(columns)) VALUES (new.rowid, \(columns.split(separator: ",").map { "new.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")));
            END;
            """)
            try exec("""
            CREATE TRIGGER IF NOT EXISTS \(table)_ad AFTER DELETE ON \(table) BEGIN
                INSERT INTO \(ftsTable)(\(ftsTable), rowid, \(columns)) VALUES ('delete', old.rowid, \(columns.split(separator: ",").map { "old.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")));
            END;
            """)
            try exec("""
            CREATE TRIGGER IF NOT EXISTS \(table)_au AFTER UPDATE ON \(table) BEGIN
                INSERT INTO \(ftsTable)(\(ftsTable), rowid, \(columns)) VALUES ('delete', old.rowid, \(columns.split(separator: ",").map { "old.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")));
                INSERT INTO \(ftsTable)(rowid, \(columns)) VALUES (new.rowid, \(columns.split(separator: ",").map { "new.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")));
            END;
            """)
        }
    }

    // MARK: - Pages

    @discardableResult
    func createPage(chatID: String = defaultChatID, title: String, provider: String, closingCurrentActivePage: Bool = true) throws -> StandaloneChatPage {
        let now = Date()
        let previous = closingCurrentActivePage ? try activePage(chatID: chatID) : nil
        if let active = previous {
            try closePage(id: active.id)
        }
        let page = StandaloneChatPage(
            id: UUID().uuidString, chatID: chatID, title: title, summary: nil,
            createdAt: now, closedAt: nil, provider: provider, providerSessionID: nil, messageCount: 0
        )
        try exec(
            "INSERT INTO chat_pages (id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
            bindings: [.text(page.id), .text(page.chatID), .text(page.title), .null, .text(iso(now)), .null, .text(page.provider), .null, .integer(0)]
        )
        if isOutsideTransaction {
            if let previous { try syncPageFile(pageID: previous.id) }
            try syncPageFile(pageID: page.id)
        }
        return page
    }

    func activePage(chatID: String = defaultChatID) throws -> StandaloneChatPage? {
        try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? AND closed_at IS NULL ORDER BY created_at DESC LIMIT 1;",
            bindings: [.text(chatID)]
        ).first
    }

    func closePage(id: String) throws {
        try exec("UPDATE chat_pages SET closed_at = ? WHERE id = ?;", bindings: [.text(iso(Date())), .text(id)])
        if isOutsideTransaction { try syncPageFile(pageID: id) }
    }

    func setPageTitle(pageID: String, title: String) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StandaloneChatStoreError.queryFailed("A chat page title cannot be empty.")
        }
        try exec("UPDATE chat_pages SET title = ? WHERE id = ?;", bindings: [.text(normalized), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    /// Atomically creates the fallback-classified page and moves the missed turn onto it.
    /// A failure cannot leave an empty new active page while the turn remains on its predecessor.
    func createPageAndMoveMessages(turnID: String, fromPageID: String, title: String, provider: String) throws -> StandaloneChatPage {
        try exec("BEGIN IMMEDIATE;")
        do {
            let page = try createPage(title: title, provider: provider)
            try exec(
                "UPDATE chat_messages SET page_id = ? WHERE page_id = ? AND turn_id = ?;",
                bindings: [.text(page.id), .text(fromPageID), .text(turnID)]
            )
            try exec("UPDATE chat_pages SET message_count = (SELECT count(*) FROM chat_messages WHERE page_id = ?) WHERE id = ?;", bindings: [.text(fromPageID), .text(fromPageID)])
            try exec("UPDATE chat_pages SET message_count = (SELECT count(*) FROM chat_messages WHERE page_id = ?) WHERE id = ?;", bindings: [.text(page.id), .text(page.id)])
            try reindexMessages(pageID: fromPageID)
            try reindexMessages(pageID: page.id)
            try exec("COMMIT;")
            try syncPageFile(pageID: fromPageID)
            try syncPageFile(pageID: page.id)
            return try self.page(id: page.id)
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func reindexMessages(pageID: String) throws {
        var ids: [String] = []
        try withStatement(
            "SELECT id FROM chat_messages WHERE page_id = ? ORDER BY rowid ASC;",
            bindings: [.text(pageID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { ids.append(columnText(statement, 0)) }
        }
        for (index, id) in ids.enumerated() {
            try exec(
                "UPDATE chat_messages SET timeline_order = ? WHERE id = ?;",
                bindings: [.integer(Int64(index)), .text(id)]
            )
        }
    }

    func setSummary(pageID: String, summary: String) throws {
        try exec("UPDATE chat_pages SET summary = ? WHERE id = ?;", bindings: [.text(summary), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    func setProviderSession(pageID: String, sessionID: String) throws {
        try exec("UPDATE chat_pages SET provider_session_id = ? WHERE id = ?;", bindings: [.text(sessionID), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    /// Binds a page to the provider session that holds only this page's turns, so each page
    /// is its own standalone provider context instead of sharing one ever-growing session.
    func setProviderSession(pageID: String, provider: String, sessionID: String) throws {
        try exec(
            "UPDATE chat_pages SET provider_session_id = ?, provider = ? WHERE id = ?;",
            bindings: [.text(sessionID), .text(provider), .text(pageID)]
        )
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    func listPages(chatID: String = defaultChatID, limit: Int = 50) throws -> [StandaloneChatPage] {
        try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? ORDER BY created_at DESC LIMIT ?;",
            bindings: [.text(chatID), .integer(Int64(limit))]
        )
    }

    /// Resolves which page the in-flight turn belongs to, per the agent's mandatory
    /// end-of-turn `chat page close-turn` signal (see AGENTS-adjacent plan doc):
    /// `continues == false` closes the active page and starts a fresh one titled
    /// `newTitle`; `continues == true` (or an inferred default when no signal arrived)
    /// appends to the current active page, creating one if this is the very first turn.
    @discardableResult
    func resolveTurnPage(chatID: String = defaultChatID, provider: String, continues: Bool, newTitle: String?) throws -> StandaloneChatPage {
        if !continues {
            guard let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StandaloneChatStoreError.queryFailed("A new page requires --new-title when --continues is false.")
            }
            return try createPage(chatID: chatID, title: newTitle, provider: provider)
        }
        if let active = try activePage(chatID: chatID) { return active }
        return try createPage(chatID: chatID, title: "New conversation", provider: provider, closingCurrentActivePage: false)
    }

    // MARK: - Compliance tracking

    /// Call once per real `chat page new`/`close-turn` CLI invocation (not the auto-fallback
    /// page creation), so a turn's compliance can be checked by comparing the sequence before
    /// and after the turn ran.
    func recordSignal(chatID: String = defaultChatID) throws {
        try exec(
            """
            INSERT INTO chat_meta (chat_id, signal_sequence, last_turn_missed_signal) VALUES (?, 1, 0)
            ON CONFLICT(chat_id) DO UPDATE SET signal_sequence = signal_sequence + 1;
            """,
            bindings: [.text(chatID)]
        )
    }

    func signalSequence(chatID: String = defaultChatID) throws -> Int {
        var value = 0
        try withStatement("SELECT signal_sequence FROM chat_meta WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { value = Int(sqlite3_column_int64(statement, 0)) }
        }
        return value
    }

    func setLastTurnMissedSignal(_ missed: Bool, chatID: String = defaultChatID) throws {
        try exec(
            """
            INSERT INTO chat_meta (chat_id, signal_sequence, last_turn_missed_signal) VALUES (?, 0, ?)
            ON CONFLICT(chat_id) DO UPDATE SET last_turn_missed_signal = excluded.last_turn_missed_signal;
            """,
            bindings: [.text(chatID), .integer(missed ? 1 : 0)]
        )
    }

    func lastTurnMissedSignal(chatID: String = defaultChatID) throws -> Bool {
        var value = false
        try withStatement("SELECT last_turn_missed_signal FROM chat_meta WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { value = sqlite3_column_int64(statement, 0) != 0 }
        }
        return value
    }

    func setPendingFallback(pageID: String, turnID: String, chatID: String = defaultChatID) throws {
        try exec(
            "INSERT INTO chat_pending_fallback (chat_id, page_id, turn_id) VALUES (?, ?, ?) ON CONFLICT(chat_id) DO UPDATE SET page_id = excluded.page_id, turn_id = excluded.turn_id;",
            bindings: [.text(chatID), .text(pageID), .text(turnID)]
        )
    }

    func markPendingFallback(pageID: String, turnID: String, chatID: String = defaultChatID) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try setLastTurnMissedSignal(true, chatID: chatID)
            try setPendingFallback(pageID: pageID, turnID: turnID, chatID: chatID)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Reconstructs a missing pending pointer only while its missed-signal marker,
    /// active page, and latest turn still match. An explicit page start wins if it
    /// commits first because it clears the marker and changes the active page.
    func recoverPendingFallbackIfActive(pageID: String, turnID: String, chatID: String = defaultChatID) throws -> Bool {
        try exec("BEGIN IMMEDIATE;")
        do {
            guard try pendingFallback(chatID: chatID) == nil,
                  try lastTurnMissedSignal(chatID: chatID),
                  try activePage(chatID: chatID)?.id == pageID,
                  try messages(pageID: pageID).last?.turnID == turnID else {
                try exec("ROLLBACK;")
                return false
            }
            try setPendingFallback(pageID: pageID, turnID: turnID, chatID: chatID)
            try exec("COMMIT;")
            return true
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func pendingFallback(chatID: String = defaultChatID) throws -> StandaloneChatPendingFallback? {
        var pending: StandaloneChatPendingFallback?
        try withStatement(
            "SELECT page_id, turn_id FROM chat_pending_fallback WHERE chat_id = ?;",
            bindings: [.text(chatID)]
        ) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                pending = StandaloneChatPendingFallback(pageID: columnText(statement, 0), turnID: columnText(statement, 1))
            }
        }
        return pending
    }

    func hasPendingFallback(chatID: String = defaultChatID) throws -> Bool {
        try pendingFallback(chatID: chatID) != nil
    }

    func clearPendingFallback(turnID: String? = nil, chatID: String = defaultChatID) throws {
        if let turnID {
            try exec("DELETE FROM chat_pending_fallback WHERE chat_id = ? AND turn_id = ?;", bindings: [.text(chatID), .text(turnID)])
        } else {
            try exec("DELETE FROM chat_pending_fallback WHERE chat_id = ?;", bindings: [.text(chatID)])
        }
    }

    /// Starts an explicitly requested page and supersedes any unresolved fallback
    /// in one transaction, so a late classifier cannot race this user choice.
    func createExplicitPage(chatID: String = defaultChatID, title: String, provider: String) throws -> StandaloneChatPage {
        try exec("BEGIN IMMEDIATE;")
        do {
            let previousPageID = try activePage(chatID: chatID)?.id
            try clearPendingFallback(chatID: chatID)
            try setLastTurnMissedSignal(false, chatID: chatID)
            let page = try createPage(chatID: chatID, title: title, provider: provider)
            try recordSignal(chatID: chatID)
            try exec("COMMIT;")
            if let previousPageID { try syncPageFile(pageID: previousPageID) }
            try syncPageFile(pageID: page.id)
            return page
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Applies a classifier result only if its exact pending turn is still the
    /// current unresolved turn. Validation and all resulting page/message writes
    /// share one SQLite transaction with BEGIN IMMEDIATE.
    @discardableResult
    func applyFallbackClassification(
        chatID: String = defaultChatID,
        pageID: String,
        turnID: String,
        continues: Bool,
        title: String?,
        provider: String,
        hasPriorUserMessage: Bool
    ) throws -> Bool {
        var changedPageIDs: [String] = [pageID]
        try exec("BEGIN IMMEDIATE;")
        do {
            guard try pendingFallback(chatID: chatID) == StandaloneChatPendingFallback(pageID: pageID, turnID: turnID),
                  try activePage(chatID: chatID)?.id == pageID,
                  try messages(pageID: pageID).last?.turnID == turnID else {
                try exec("ROLLBACK;")
                return false
            }

            if hasPriorUserMessage {
                if !continues, let title {
                    let newPage = try createPage(chatID: chatID, title: title, provider: provider)
                    changedPageIDs.append(newPage.id)
                    try exec(
                        "UPDATE chat_messages SET page_id = ? WHERE page_id = ? AND turn_id = ?;",
                        bindings: [.text(newPage.id), .text(pageID), .text(turnID)]
                    )
                    try exec("UPDATE chat_pages SET message_count = (SELECT count(*) FROM chat_messages WHERE page_id = ?) WHERE id = ?;", bindings: [.text(pageID), .text(pageID)])
                    try exec("UPDATE chat_pages SET message_count = (SELECT count(*) FROM chat_messages WHERE page_id = ?) WHERE id = ?;", bindings: [.text(newPage.id), .text(newPage.id)])
                    try reindexMessages(pageID: pageID)
                    try reindexMessages(pageID: newPage.id)
                }
            } else if let title {
                try setPageTitle(pageID: pageID, title: title)
            }
            try setLastTurnMissedSignal(false, chatID: chatID)
            try clearPendingFallback(turnID: turnID, chatID: chatID)
            try exec("COMMIT;")
            for changedPageID in changedPageIDs { try syncPageFile(pageID: changedPageID) }
            return true
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func page(id: String) throws -> StandaloneChatPage {
        guard let page = try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE id = ?;",
            bindings: [.text(id)]
        ).first else {
            throw StandaloneChatStoreError.notFound("No chat page with id \(id).")
        }
        return page
    }

    // MARK: - Messages

    @discardableResult
    func appendMessage(pageID: String, turnID: String, role: String, text: String) throws -> StandaloneChatMessage {
        let page = try page(id: pageID)
        let message = StandaloneChatMessage(
            id: UUID().uuidString, pageID: pageID, turnID: turnID, role: role, text: text,
            createdAt: Date(), timelineOrder: page.messageCount
        )
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec(
                "INSERT INTO chat_messages (id, page_id, turn_id, role, text, created_at, timeline_order) VALUES (?, ?, ?, ?, ?, ?, ?);",
                bindings: [.text(message.id), .text(pageID), .text(turnID), .text(role), .text(text), .text(iso(message.createdAt)), .integer(Int64(message.timelineOrder))]
            )
            try exec("UPDATE chat_pages SET message_count = message_count + 1 WHERE id = ?;", bindings: [.text(pageID)])
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try syncPageFile(pageID: pageID)
        return message
    }

    func pageFileURL(pageID: String) -> URL {
        pageFilesDirectory.appendingPathComponent("\(pageID).json")
    }

    var pageFilesDirectoryURL: URL { pageFilesDirectory }

    private var isOutsideTransaction: Bool {
        guard let database else { return false }
        return sqlite3_get_autocommit(database) != 0
    }

    private func syncAllPageFiles(chatID: String = defaultChatID) throws {
        try FileManager.default.createDirectory(at: pageFilesDirectory, withIntermediateDirectories: true)
        _ = Darwin.chmod(pageFilesDirectory.path, mode_t(0o700))
        let pages = try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? ORDER BY created_at ASC;",
            bindings: [.text(chatID)]
        )
        for page in pages { try syncPageFile(pageID: page.id) }
    }

    /// Migrate pages that predate file archives once. Normal reads never scan or
    /// rewrite the full archive; later mutations sync only the pages they change.
    private func backfillPageFilesIfNeeded() throws {
        Self.pageFileBackfillLock.lock()
        defer { Self.pageFileBackfillLock.unlock() }
        var alreadyBackfilled = false
        try withStatement("SELECT 1 FROM chat_archive_migrations WHERE version = 1 LIMIT 1;", bindings: []) { statement in
            alreadyBackfilled = sqlite3_step(statement) == SQLITE_ROW
        }
        guard !alreadyBackfilled else { return }
        try syncAllPageFiles()
        try exec("INSERT OR IGNORE INTO chat_archive_migrations (version) VALUES (1);")
    }

    private func syncPageFile(pageID: String) throws {
        try FileManager.default.createDirectory(at: pageFilesDirectory, withIntermediateDirectories: true)
        _ = Darwin.chmod(pageFilesDirectory.path, mode_t(0o700))
        let url = pageFileURL(pageID: pageID)
        Self.pageFileProcessLock.lock()
        defer { Self.pageFileProcessLock.unlock() }
        let locksDirectory = pageFilesDirectory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        _ = Darwin.chmod(locksDirectory.path, mode_t(0o700))
        let descriptor = Darwin.open(locksDirectory.appendingPathComponent("\(pageID).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw StandaloneChatStoreError.queryFailed("Couldn't lock the standalone chat page archive.") }
        defer { _ = Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else {
            throw StandaloneChatStoreError.queryFailed("Couldn't lock the standalone chat page archive.")
        }
        defer { lock.l_type = Int16(F_UNLCK); _ = Darwin.fcntl(descriptor, F_SETLK, &lock) }

        try exec("BEGIN;")
        let archive: StandaloneChatPageArchive
        do {
            archive = StandaloneChatPageArchive(
                formatVersion: 1,
                page: try page(id: pageID),
                messages: try messages(pageID: pageID)
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: url, options: .atomic)
        _ = Darwin.chmod(url.path, mode_t(0o600))
    }

    func messages(pageID: String) throws -> [StandaloneChatMessage] {
        var results: [StandaloneChatMessage] = []
        try withStatement("SELECT id, page_id, turn_id, role, text, created_at, timeline_order FROM chat_messages WHERE page_id = ? ORDER BY timeline_order ASC;", bindings: [.text(pageID)]) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(StandaloneChatMessage(
                    id: columnText(statement, 0), pageID: columnText(statement, 1), turnID: columnText(statement, 2),
                    role: columnText(statement, 3), text: columnText(statement, 4),
                    createdAt: date(columnText(statement, 5)), timelineOrder: Int(sqlite3_column_int64(statement, 6))
                ))
            }
        }
        return results
    }

    func pageAssignmentsByTurnID(chatID: String = defaultChatID) throws -> [String: StandaloneChatPage] {
        var assignments: [String: StandaloneChatPage] = [:]
        try withStatement(
            "SELECT DISTINCT m.turn_id, p.id, p.chat_id, p.title, p.summary, p.created_at, p.closed_at, p.provider, p.provider_session_id, p.message_count FROM chat_messages m JOIN chat_pages p ON p.id = m.page_id WHERE p.chat_id = ? ORDER BY p.created_at ASC;",
            bindings: [.text(chatID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let page = StandaloneChatPage(
                    id: columnText(statement, 1), chatID: columnText(statement, 2), title: columnText(statement, 3),
                    summary: columnTextOrNil(statement, 4), createdAt: date(columnText(statement, 5)),
                    closedAt: columnTextOrNil(statement, 6).map(date), provider: columnText(statement, 7),
                    providerSessionID: columnTextOrNil(statement, 8), messageCount: Int(sqlite3_column_int64(statement, 9))
                )
                assignments[columnText(statement, 0)] = page
            }
        }
        return assignments
    }

    // MARK: - Search

    func searchPages(chatID: String = defaultChatID, query: String, limit: Int = 10) throws -> [StandaloneChatPageMatch] {
        var results: [StandaloneChatPageMatch] = []
        let sql = """
        SELECT p.id, p.chat_id, p.title, p.summary, p.created_at, p.closed_at, p.provider, p.provider_session_id, p.message_count,
               snippet(chat_pages_fts, 1, '[', ']', '…', 12) AS snip, bm25(chat_pages_fts) AS rank
        FROM chat_pages_fts
        JOIN chat_pages p ON p.rowid = chat_pages_fts.rowid
        WHERE chat_pages_fts MATCH ? AND p.chat_id = ?
        ORDER BY rank LIMIT ?;
        """
        try withStatement(sql, bindings: [.text(ftsQuery(query)), .text(chatID), .integer(Int64(limit))]) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let page = StandaloneChatPage(
                    id: columnText(statement, 0), chatID: columnText(statement, 1), title: columnText(statement, 2),
                    summary: columnTextOrNil(statement, 3), createdAt: date(columnText(statement, 4)),
                    closedAt: columnTextOrNil(statement, 5).map(date), provider: columnText(statement, 6),
                    providerSessionID: columnTextOrNil(statement, 7), messageCount: Int(sqlite3_column_int64(statement, 8))
                )
                results.append(StandaloneChatPageMatch(page: page, snippet: columnText(statement, 9), rank: sqlite3_column_double(statement, 10)))
            }
        }
        if !results.isEmpty { return results }
        // Fall back to a message-level match surfaced as its parent page, for queries that hit
        // specific wording inside a message rather than the page's title/summary.
        let messageSQL = """
        SELECT p.id, p.chat_id, p.title, p.summary, p.created_at, p.closed_at, p.provider, p.provider_session_id, p.message_count,
               snippet(chat_messages_fts, 0, '[', ']', '…', 12) AS snip, bm25(chat_messages_fts) AS rank
        FROM chat_messages_fts
        JOIN chat_messages m ON m.rowid = chat_messages_fts.rowid
        JOIN chat_pages p ON p.id = m.page_id
        WHERE chat_messages_fts MATCH ? AND p.chat_id = ?
        ORDER BY rank LIMIT ?;
        """
        try withStatement(messageSQL, bindings: [.text(ftsQuery(query)), .text(chatID), .integer(Int64(limit))]) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let page = StandaloneChatPage(
                    id: columnText(statement, 0), chatID: columnText(statement, 1), title: columnText(statement, 2),
                    summary: columnTextOrNil(statement, 3), createdAt: date(columnText(statement, 4)),
                    closedAt: columnTextOrNil(statement, 5).map(date), provider: columnText(statement, 6),
                    providerSessionID: columnTextOrNil(statement, 7), messageCount: Int(sqlite3_column_int64(statement, 8))
                )
                results.append(StandaloneChatPageMatch(page: page, snippet: columnText(statement, 9), rank: sqlite3_column_double(statement, 10)))
            }
        }
        return results
    }

    private func ftsQuery(_ query: String) -> String {
        // Treat the user's free-form query as an AND of quoted terms so punctuation/operators
        // in natural language (e.g. "what's", "page 2?") can't be mistaken for FTS5 syntax.
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !terms.isEmpty else { return "\"\(query.replacingOccurrences(of: "\"", with: ""))\"" }
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int64)
        case null
    }

    private func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    private func date(_ string: String) -> Date { isoFormatter.date(from: string) ?? .distantPast }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func columnTextOrNil(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func exec(_ sql: String, bindings: [Binding] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                throw StandaloneChatStoreError.queryFailed(self.lastErrorMessage())
            }
        }
    }

    private func withStatement(_ sql: String, bindings: [Binding], _ body: (OpaquePointer?) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StandaloneChatStoreError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        try body(statement)
    }

    private func queryPages(_ sql: String, bindings: [Binding]) throws -> [StandaloneChatPage] {
        var results: [StandaloneChatPage] = []
        try withStatement(sql, bindings: bindings) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(StandaloneChatPage(
                    id: columnText(statement, 0), chatID: columnText(statement, 1), title: columnText(statement, 2),
                    summary: columnTextOrNil(statement, 3), createdAt: date(columnText(statement, 4)),
                    closedAt: columnTextOrNil(statement, 5).map(date), provider: columnText(statement, 6),
                    providerSessionID: columnTextOrNil(statement, 7), messageCount: Int(sqlite3_column_int64(statement, 8))
                ))
            }
        }
        return results
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(database))
    }
}

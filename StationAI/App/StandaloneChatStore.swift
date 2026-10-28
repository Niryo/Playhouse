import Foundation
import SQLite3

/// Persistence and search for the standalone chat feature's "pages": a continuous,
/// repo/worktree-free conversation split into titled segments so the live provider
/// context stays bounded while the full archive remains locally searchable.
///
/// Storage lives in its own SQLite database (separate from the SwiftData task store),
/// mirroring `StationAIStore`'s per-worktree data-directory isolation so e2e fixtures
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

    private var database: OpaquePointer?
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
        let supportDirectory = try StationAIAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent("StandaloneChat-v1.sqlite")
    }

    init(dataDirectory: String? = nil) throws {
        let url = try Self.storeURL(dataDirectory: dataDirectory)
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
        if closingCurrentActivePage, let active = try activePage(chatID: chatID) {
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
    }

    func setSummary(pageID: String, summary: String) throws {
        try exec("UPDATE chat_pages SET summary = ? WHERE id = ?;", bindings: [.text(summary), .text(pageID)])
    }

    func setProviderSession(pageID: String, sessionID: String) throws {
        try exec("UPDATE chat_pages SET provider_session_id = ? WHERE id = ?;", bindings: [.text(sessionID), .text(pageID)])
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
        try exec(
            "INSERT INTO chat_messages (id, page_id, turn_id, role, text, created_at, timeline_order) VALUES (?, ?, ?, ?, ?, ?, ?);",
            bindings: [.text(message.id), .text(pageID), .text(turnID), .text(role), .text(text), .text(iso(message.createdAt)), .integer(Int64(message.timelineOrder))]
        )
        try exec("UPDATE chat_pages SET message_count = message_count + 1 WHERE id = ?;", bindings: [.text(pageID)])
        return message
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

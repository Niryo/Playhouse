import Foundation
import GRDBSQLite

/// Persistence and search for the standalone chat feature's "pages": a continuous,
/// repo/worktree-free conversation split into titled segments so the live provider
/// context stays bounded while the full archive remains locally searchable.
///
/// Storage lives in its own SQLite database (separate from the task store),
/// mirroring `PlayhouseStore`'s per-worktree data-directory isolation so e2e fixtures
/// and distinct app instances never share chat history.
package struct StandaloneChatPage: Codable, Equatable {
    package var id: String
    package var chatID: String
    package var title: String
    package var summary: String?
    package var createdAt: Date
    package var closedAt: Date?
    package var provider: String
    package var providerSessionID: String?
    package var messageCount: Int

    /// The provider session that holds only this page's turns. A page records one session at a
    /// time: switching provider mid-page starts that provider's own fresh session for the page.
    package func conversationID(forProvider provider: String) -> String? {
        guard self.provider == provider, let providerSessionID, !providerSessionID.isEmpty else { return nil }
        return providerSessionID
    }

    package init(id: String, chatID: String, title: String, summary: String? = nil, createdAt: Date, closedAt: Date? = nil, provider: String, providerSessionID: String? = nil, messageCount: Int) {
        self.id = id
        self.chatID = chatID
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.closedAt = closedAt
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.messageCount = messageCount
    }
}

package struct StandaloneChatMessage: Codable, Equatable {
    package var id: String
    package var pageID: String
    package var turnID: String
    package var role: String
    package var text: String
    package var createdAt: Date
    package var timelineOrder: Int

    package init(id: String, pageID: String, turnID: String, role: String, text: String, createdAt: Date, timelineOrder: Int) {
        self.id = id
        self.pageID = pageID
        self.turnID = turnID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.timelineOrder = timelineOrder
    }
}

package struct StandaloneChatPageMatch: Codable, Equatable {
    package var page: StandaloneChatPage
    package var snippet: String
    package var rank: Double

    package init(page: StandaloneChatPage, snippet: String, rank: Double) {
        self.page = page
        self.snippet = snippet
        self.rank = rank
    }
}

package struct StandaloneChatPendingFallback: Equatable {
    package var pageID: String
    package var turnID: String

    package init(pageID: String, turnID: String) {
        self.pageID = pageID
        self.turnID = turnID
    }
}

/// One `chat page close-turn`, kept with the page it resolved to. The command runs inside the
/// turn it settles, so the turn whose time span holds the signal is the turn that owns it: a
/// daemon that never saw the turn start (it took over after a restart) can still file the turn
/// on the page its agent chose.
package struct StandaloneChatTurnSignal: Equatable {
    package var pageID: String
    package var recordedAt: Date

    package init(pageID: String, recordedAt: Date) {
        self.pageID = pageID
        self.recordedAt = recordedAt
    }
}

/// A message of a turn being filed onto a page.
package struct StandaloneChatTurnMessage: Equatable {
    package var role: String
    package var text: String
    package var createdAt: Date?

    package init(role: String, text: String, createdAt: Date? = nil) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

private struct StandaloneChatPageArchive: Codable {
    let formatVersion: Int
    let page: StandaloneChatPage
    let messages: [StandaloneChatMessage]
}

package enum StandaloneChatStoreError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case notFound(String)

    package var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open the standalone chat database: \(message)"
        case .queryFailed(let message): "Standalone chat query failed: \(message)"
        case .notFound(let message): message
        }
    }
}

package final class StandaloneChatManager {
    package static let defaultChatID = "default"
    /// The title a page the user starts carries until its first turn names it.
    package static let newPageTitle = "New page"
    private static let pageFileProcessLock = NSLock()
    private static let pageFileBackfillLock = NSLock()

    /// The chat whose pages and turn bookkeeping this manager reads and writes: the
    /// standalone chat itself, or one of its parallel bubbles while that bubble runs.
    package let chatID: String
    private var database: OpaquePointer?
    private let pageFilesDirectory: URL
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    package static func storeURL(dataDirectory: String? = nil) throws -> URL {
        if let dataDirectory {
            return URL(fileURLWithPath: dataDirectory, isDirectory: true)
                .appendingPathComponent("StandaloneChat-v1.sqlite")
        }
        let supportDirectory = try PlayhouseAppIdentity.defaultDataDirectory()
        return supportDirectory.appendingPathComponent("StandaloneChat-v1.sqlite")
    }

    package init(dataDirectory: String? = nil, chatID: String = StandaloneChatManager.defaultChatID) throws {
        self.chatID = chatID
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
        // The page labels read the newest pages, a few at a time, without sorting every page.
        try exec("CREATE INDEX IF NOT EXISTS chat_pages_chat_created_idx ON chat_pages(chat_id, created_at);")
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
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_turn_signals (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id TEXT NOT NULL,
            page_id TEXT NOT NULL,
            recorded_at TEXT NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS chat_turn_signals_time_idx ON chat_turn_signals(chat_id, recorded_at);")
        try exec("CREATE INDEX IF NOT EXISTS chat_messages_turn_idx ON chat_messages(turn_id);")
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_inflight_turn (
            chat_id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL
        );
        """)
        // The page the user last started with the composer's New page button. While no turn has
        // filled it, its first turn names it and a send without New page undoes it.
        try exec("""
        CREATE TABLE IF NOT EXISTS chat_user_new_page (
            chat_id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL
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
    package func createPage(title: String, provider: String, closingCurrentActivePage: Bool = true) throws -> StandaloneChatPage {
        let now = Date()
        let previous = closingCurrentActivePage ? try activePage() : nil
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

    package func activePage() throws -> StandaloneChatPage? {
        try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? AND closed_at IS NULL ORDER BY created_at DESC LIMIT 1;",
            bindings: [.text(chatID)]
        ).first
    }

    package func closePage(id: String) throws {
        try exec("UPDATE chat_pages SET closed_at = ? WHERE id = ?;", bindings: [.text(iso(Date())), .text(id)])
        if isOutsideTransaction { try syncPageFile(pageID: id) }
    }

    package func setPageTitle(pageID: String, title: String) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw StandaloneChatStoreError.queryFailed("A chat page title cannot be empty.")
        }
        try exec("UPDATE chat_pages SET title = ? WHERE id = ?;", bindings: [.text(normalized), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    /// Atomically creates the fallback-classified page and moves the missed turn onto it.
    /// A failure cannot leave an empty new active page while the turn remains on its predecessor.
    package func createPageAndMoveMessages(turnID: String, fromPageID: String, title: String, provider: String) throws -> StandaloneChatPage {
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
            // A recovered turn can be filed between turns already on the page, so its
            // timeline position, not its insertion order, is the page's order.
            "SELECT id FROM chat_messages WHERE page_id = ? ORDER BY timeline_order ASC, rowid ASC;",
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

    package func setSummary(pageID: String, summary: String) throws {
        try exec("UPDATE chat_pages SET summary = ? WHERE id = ?;", bindings: [.text(summary), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    package func setProviderSession(pageID: String, sessionID: String) throws {
        try exec("UPDATE chat_pages SET provider_session_id = ? WHERE id = ?;", bindings: [.text(sessionID), .text(pageID)])
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    /// Binds a page to the provider session that holds only this page's turns, so each page
    /// is its own standalone provider context instead of sharing one ever-growing session.
    package func setProviderSession(pageID: String, provider: String, sessionID: String) throws {
        try exec(
            "UPDATE chat_pages SET provider_session_id = ?, provider = ? WHERE id = ?;",
            bindings: [.text(sessionID), .text(provider), .text(pageID)]
        )
        if isOutsideTransaction { try syncPageFile(pageID: pageID) }
    }

    /// The newest pages, or with `titleContaining` only those whose title contains that text,
    /// ignoring case, as the search above the chat's page labels finds them.
    package func listPages(limit: Int = 50, titleContaining: String? = nil) throws -> [StandaloneChatPage] {
        let titleText = titleContaining?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !titleText.isEmpty else {
            return try queryPages(
                "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? ORDER BY created_at DESC LIMIT ?;",
                bindings: [.text(chatID), .integer(Int64(limit))]
            )
        }
        // The title's own % and _ match only themselves.
        let pattern = "%" + titleText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        return try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? AND title LIKE ? ESCAPE '\\' ORDER BY created_at DESC LIMIT ?;",
            bindings: [.text(chatID), .text(pattern), .integer(Int64(limit))]
        )
    }

    /// Resolves which page the in-flight turn belongs to, per the agent's mandatory
    /// end-of-turn `chat page close-turn` signal (see AGENTS-adjacent plan doc):
    /// `continues == false` closes the active page and starts a fresh one titled
    /// `newTitle`; `continues == true` (or an inferred default when no signal arrived)
    /// appends to the current active page, creating one if this is the very first turn.
    @discardableResult
    package func resolveTurnPage(provider: String, continues: Bool, newTitle: String?) throws -> StandaloneChatPage {
        let title = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The page the user started for this turn is already the turn's own page: a title names it.
        if let userPage = try unstartedUserNewPage() {
            if !title.isEmpty { try setPageTitle(pageID: userPage.id, title: title) }
            return try page(id: userPage.id)
        }
        if !continues {
            guard !title.isEmpty else {
                throw StandaloneChatStoreError.queryFailed("A new page requires --new-title when --continues is false.")
            }
            return try createPage(title: title, provider: provider)
        }
        if let active = try activePage() { return active }
        return try createPage(title: "New conversation", provider: provider, closingCurrentActivePage: false)
    }

    // MARK: - Compliance tracking

    /// Call once per real `chat page new`/`close-turn` CLI invocation (not the auto-fallback
    /// page creation), so a turn's compliance can be checked by comparing the sequence before
    /// and after the turn ran.
    package func recordSignal() throws {
        try exec(
            """
            INSERT INTO chat_meta (chat_id, signal_sequence, last_turn_missed_signal) VALUES (?, 1, 0)
            ON CONFLICT(chat_id) DO UPDATE SET signal_sequence = signal_sequence + 1;
            """,
            bindings: [.text(chatID)]
        )
    }

    // MARK: - In-flight turn

    /// Records that Playhouse started sending a chat turn. It stays until the turn is filed (or
    /// its send fails while its daemon is alive), so a daemon that took the turn over after a
    /// restart knows when it began even when its provider's messages carry no time (Codex), and
    /// recovery knows the newest turn really ran.
    package func beginTurn() throws {
        try exec(
            "INSERT INTO chat_inflight_turn (chat_id, started_at) VALUES (?, ?) ON CONFLICT(chat_id) DO UPDATE SET started_at = excluded.started_at;",
            bindings: [.text(chatID), .text(iso(Date()))]
        )
    }

    package func inflightTurnStartedAt() throws -> Date? {
        var startedAt: Date?
        try withStatement("SELECT started_at FROM chat_inflight_turn WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { startedAt = date(columnText(statement, 0)) }
        }
        return startedAt
    }

    package func endTurn() throws {
        try exec("DELETE FROM chat_inflight_turn WHERE chat_id = ?;", bindings: [.text(chatID)])
    }

    /// Records a `chat page close-turn` signal: it counts toward the turn's compliance check
    /// and keeps the page it resolved to with its time, in one transaction.
    package func recordTurnSignal(pageID: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try recordSignal()
            try exec(
                "INSERT INTO chat_turn_signals (chat_id, page_id, recorded_at) VALUES (?, ?, ?);",
                bindings: [.text(chatID), .text(pageID), .text(iso(Date()))]
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// The close-turn signals recorded from `start` up to (not including) `end`, oldest first.
    package func turnSignals(from start: Date, to end: Date? = nil) throws -> [StandaloneChatTurnSignal] {
        var signals: [StandaloneChatTurnSignal] = []
        try withStatement(
            "SELECT page_id, recorded_at FROM chat_turn_signals WHERE chat_id = ? AND recorded_at >= ? AND recorded_at < ? ORDER BY seq ASC;",
            bindings: [.text(chatID), .text(iso(start)), .text(end.map(iso) ?? "9999")]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                signals.append(StandaloneChatTurnSignal(pageID: columnText(statement, 0), recordedAt: date(columnText(statement, 1))))
            }
        }
        return signals
    }

    /// Pages created from `start` up to (not including) `end`, oldest first.
    package func pagesCreated(from start: Date, to end: Date) throws -> [StandaloneChatPage] {
        try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? AND created_at >= ? AND created_at < ? ORDER BY created_at ASC;",
            bindings: [.text(chatID), .text(iso(start)), .text(iso(end))]
        )
    }

    /// Moves a closing parallel bubble's pages into this chat as closed pages dated to their
    /// place in this chat's history, and drops the bubble's own turn bookkeeping. Running it
    /// again after an interrupted close finds nothing left to move.
    package func adoptPages(fromChatID bubbleChatID: String, createdAt dates: [String: Date]) throws {
        let now = iso(Date())
        try exec("BEGIN IMMEDIATE;")
        do {
            for (pageID, createdAt) in dates {
                try exec(
                    "UPDATE chat_pages SET chat_id = ?, created_at = ?, closed_at = COALESCE(closed_at, ?) WHERE id = ? AND chat_id = ?;",
                    bindings: [.text(chatID), .text(iso(createdAt)), .text(now), .text(pageID), .text(bubbleChatID)]
                )
            }
            for table in ["chat_meta", "chat_pending_fallback", "chat_turn_signals", "chat_inflight_turn", "chat_user_new_page"] {
                try exec("DELETE FROM \(table) WHERE chat_id = ?;", bindings: [.text(bubbleChatID)])
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        for pageID in dates.keys { try syncPageFile(pageID: pageID) }
    }

    package func signalSequence() throws -> Int {
        var value = 0
        try withStatement("SELECT signal_sequence FROM chat_meta WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { value = Int(sqlite3_column_int64(statement, 0)) }
        }
        return value
    }

    package func setLastTurnMissedSignal(_ missed: Bool) throws {
        try exec(
            """
            INSERT INTO chat_meta (chat_id, signal_sequence, last_turn_missed_signal) VALUES (?, 0, ?)
            ON CONFLICT(chat_id) DO UPDATE SET last_turn_missed_signal = excluded.last_turn_missed_signal;
            """,
            bindings: [.text(chatID), .integer(missed ? 1 : 0)]
        )
    }

    package func lastTurnMissedSignal() throws -> Bool {
        var value = false
        try withStatement("SELECT last_turn_missed_signal FROM chat_meta WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { value = sqlite3_column_int64(statement, 0) != 0 }
        }
        return value
    }

    package func setPendingFallback(pageID: String, turnID: String) throws {
        try exec(
            "INSERT INTO chat_pending_fallback (chat_id, page_id, turn_id) VALUES (?, ?, ?) ON CONFLICT(chat_id) DO UPDATE SET page_id = excluded.page_id, turn_id = excluded.turn_id;",
            bindings: [.text(chatID), .text(pageID), .text(turnID)]
        )
    }

    package func markPendingFallback(pageID: String, turnID: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try setLastTurnMissedSignal(true)
            try setPendingFallback(pageID: pageID, turnID: turnID)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Reconstructs a missing pending pointer only while its missed-signal marker,
    /// active page, and latest turn still match. An explicit page start wins if it
    /// commits first because it clears the marker and changes the active page.
    package func recoverPendingFallbackIfActive(pageID: String, turnID: String) throws -> Bool {
        try exec("BEGIN IMMEDIATE;")
        do {
            guard try pendingFallback() == nil,
                  try lastTurnMissedSignal(),
                  try activePage()?.id == pageID,
                  try messages(pageID: pageID).last?.turnID == turnID else {
                try exec("ROLLBACK;")
                return false
            }
            try setPendingFallback(pageID: pageID, turnID: turnID)
            try exec("COMMIT;")
            return true
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    package func pendingFallback() throws -> StandaloneChatPendingFallback? {
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

    package func hasPendingFallback() throws -> Bool {
        try pendingFallback() != nil
    }

    package func clearPendingFallback(turnID: String? = nil) throws {
        if let turnID {
            try exec("DELETE FROM chat_pending_fallback WHERE chat_id = ? AND turn_id = ?;", bindings: [.text(chatID), .text(turnID)])
        } else {
            try exec("DELETE FROM chat_pending_fallback WHERE chat_id = ?;", bindings: [.text(chatID)])
        }
    }

    /// Starts an explicitly requested page and supersedes any unresolved fallback
    /// in one transaction, so a late classifier cannot race this user choice.
    package func createExplicitPage(title: String, provider: String) throws -> StandaloneChatPage {
        try exec("BEGIN IMMEDIATE;")
        do {
            let previousPageID = try activePage()?.id
            try clearPendingFallback()
            try setLastTurnMissedSignal(false)
            let page = try createPage(title: title, provider: provider)
            try recordSignal()
            try exec("COMMIT;")
            if let previousPageID { try syncPageFile(pageID: previousPageID) }
            try syncPageFile(pageID: page.id)
            return page
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// The page the user started with New page, while it is the active page and no turn has
    /// filled it yet.
    package func unstartedUserNewPage() throws -> StandaloneChatPage? {
        var pageID: String?
        try withStatement("SELECT page_id FROM chat_user_new_page WHERE chat_id = ?;", bindings: [.text(chatID)]) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { pageID = columnText(statement, 0) }
        }
        guard let pageID, let active = try activePage(), active.id == pageID, active.messageCount == 0 else { return nil }
        return active
    }

    /// Starts the page a user's New page send runs on, titled `newPageTitle`, so its turn gets a
    /// fresh session without the last page's turns. A New page that no turn has filled yet, left
    /// by a send that failed, is reused, so retrying never leaves empty pages behind; it drops the
    /// session that failed send started, so the retry again opens with the New page header.
    /// Playhouse starts this page, not the agent, so unlike `chat page new` it records no page
    /// signal: the turn still owes its own close-turn, and the fallback classifier names the
    /// page when that never comes.
    package func startUserNewPage(provider: String) throws -> StandaloneChatPage {
        if let unstarted = try unstartedUserNewPage() {
            guard unstarted.providerSessionID != nil else { return unstarted }
            try exec("UPDATE chat_pages SET provider_session_id = NULL WHERE id = ?;", bindings: [.text(unstarted.id)])
            if isOutsideTransaction { try syncPageFile(pageID: unstarted.id) }
            return try page(id: unstarted.id)
        }
        try exec("BEGIN IMMEDIATE;")
        do {
            let previousPageID = try activePage()?.id
            try clearPendingFallback()
            try setLastTurnMissedSignal(false)
            let page = try createPage(title: Self.newPageTitle, provider: provider)
            try exec(
                "INSERT INTO chat_user_new_page (chat_id, page_id) VALUES (?, ?) ON CONFLICT(chat_id) DO UPDATE SET page_id = excluded.page_id;",
                bindings: [.text(chatID), .text(page.id)]
            )
            try exec("COMMIT;")
            if let previousPageID { try syncPageFile(pageID: previousPageID) }
            try syncPageFile(pageID: page.id)
            return page
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Undoes a user's New page that no turn ever filled, as when its send failed and the user
    /// then sent without New page: the empty page goes and the page it closed is the active page
    /// again, so the message continues it. Returns whether a page was undone.
    @discardableResult
    package func discardUnstartedUserNewPage() throws -> Bool {
        guard let unstarted = try unstartedUserNewPage() else { return false }
        var reopenedPageID: String?
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM chat_user_new_page WHERE chat_id = ?;", bindings: [.text(chatID)])
            try exec("DELETE FROM chat_pages WHERE id = ? AND message_count = 0;", bindings: [.text(unstarted.id)])
            reopenedPageID = try queryPages(
                "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages WHERE chat_id = ? AND closed_at IS NOT NULL ORDER BY created_at DESC LIMIT 1;",
                bindings: [.text(chatID)]
            ).first?.id
            if let reopenedPageID {
                try exec("UPDATE chat_pages SET closed_at = NULL WHERE id = ?;", bindings: [.text(reopenedPageID)])
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try? FileManager.default.removeItem(at: pageFileURL(pageID: unstarted.id))
        if let reopenedPageID { try syncPageFile(pageID: reopenedPageID) }
        return true
    }

    /// Applies a classifier result only if its exact pending turn is still the
    /// current unresolved turn. Validation and all resulting page/message writes
    /// share one SQLite transaction with BEGIN IMMEDIATE.
    @discardableResult
    package func applyFallbackClassification(
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
            guard try pendingFallback() == StandaloneChatPendingFallback(pageID: pageID, turnID: turnID),
                  try activePage()?.id == pageID,
                  try messages(pageID: pageID).last?.turnID == turnID else {
                try exec("ROLLBACK;")
                return false
            }

            if hasPriorUserMessage {
                if !continues, let title {
                    let newPage = try createPage(title: title, provider: provider)
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
            try setLastTurnMissedSignal(false)
            try clearPendingFallback(turnID: turnID)
            try exec("COMMIT;")
            for changedPageID in changedPageIDs { try syncPageFile(pageID: changedPageID) }
            return true
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    package func page(id: String) throws -> StandaloneChatPage {
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
    package func appendMessage(pageID: String, turnID: String, role: String, text: String) throws -> StandaloneChatMessage {
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

    /// Files one turn's messages onto a page, unless any page of this chat already holds that
    /// turn: the check and the writes share one transaction, so the daemon that sent a turn, a
    /// daemon that took it over after a restart, and startup recovery can never file it twice.
    /// The turn goes ahead of the first message of any of `laterTurnIDs` already on the page,
    /// otherwise at its end. Returns false when the turn was already filed.
    @discardableResult
    package func fileTurn(
        pageID: String,
        turnID: String,
        messages turnMessages: [StandaloneChatTurnMessage],
        laterTurnIDs: Set<String> = []
    ) throws -> Bool {
        try exec("BEGIN IMMEDIATE;")
        do {
            var alreadyFiled = false
            try withStatement(
                "SELECT 1 FROM chat_messages m JOIN chat_pages p ON p.id = m.page_id WHERE p.chat_id = ? AND m.turn_id = ? LIMIT 1;",
                bindings: [.text(chatID), .text(turnID)]
            ) { statement in
                alreadyFiled = sqlite3_step(statement) == SQLITE_ROW
            }
            guard !alreadyFiled else {
                try exec("ROLLBACK;")
                return false
            }
            guard !turnMessages.isEmpty else {
                try exec("ROLLBACK;")
                return true
            }
            _ = try page(id: pageID)
            let existing = try messages(pageID: pageID)
            let end = (existing.map(\.timelineOrder).max() ?? -1) + 1
            let insertAt = existing.first(where: { laterTurnIDs.contains($0.turnID) })?.timelineOrder ?? end
            if insertAt < end {
                try exec(
                    "UPDATE chat_messages SET timeline_order = timeline_order + ? WHERE page_id = ? AND timeline_order >= ?;",
                    bindings: [.integer(Int64(turnMessages.count)), .text(pageID), .integer(Int64(insertAt))]
                )
            }
            let now = Date()
            for (offset, message) in turnMessages.enumerated() {
                try exec(
                    "INSERT INTO chat_messages (id, page_id, turn_id, role, text, created_at, timeline_order) VALUES (?, ?, ?, ?, ?, ?, ?);",
                    bindings: [
                        .text(UUID().uuidString), .text(pageID), .text(turnID), .text(message.role), .text(message.text),
                        .text(iso(message.createdAt ?? now)), .integer(Int64(insertAt + offset)),
                    ]
                )
            }
            try exec(
                "UPDATE chat_pages SET message_count = (SELECT count(*) FROM chat_messages WHERE page_id = ?) WHERE id = ?;",
                bindings: [.text(pageID), .text(pageID)]
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try syncPageFile(pageID: pageID)
        return true
    }

    /// Every turn filed on any page of this chat.
    package func filedTurnIDs() throws -> Set<String> {
        var turnIDs = Set<String>()
        try withStatement(
            "SELECT DISTINCT m.turn_id FROM chat_messages m JOIN chat_pages p ON p.id = m.page_id WHERE p.chat_id = ?;",
            bindings: [.text(chatID)]
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW { turnIDs.insert(columnText(statement, 0)) }
        }
        return turnIDs
    }

    package func pageFileURL(pageID: String) -> URL {
        pageFilesDirectory.appendingPathComponent("\(pageID).json")
    }

    package var pageFilesDirectoryURL: URL { pageFilesDirectory }

    private var isOutsideTransaction: Bool {
        guard let database else { return false }
        return sqlite3_get_autocommit(database) != 0
    }

    private func syncAllPageFiles() throws {
        try FileManager.default.createDirectory(at: pageFilesDirectory, withIntermediateDirectories: true)
        _ = POSIX.chmod(pageFilesDirectory.path, mode_t(0o700))
        let pages = try queryPages(
            "SELECT id, chat_id, title, summary, created_at, closed_at, provider, provider_session_id, message_count FROM chat_pages ORDER BY created_at ASC;",
            bindings: []
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
        _ = POSIX.chmod(pageFilesDirectory.path, mode_t(0o700))
        let url = pageFileURL(pageID: pageID)
        Self.pageFileProcessLock.lock()
        defer { Self.pageFileProcessLock.unlock() }
        let locksDirectory = pageFilesDirectory.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        _ = POSIX.chmod(locksDirectory.path, mode_t(0o700))
        let descriptor = POSIX.open(locksDirectory.appendingPathComponent("\(pageID).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw StandaloneChatStoreError.queryFailed("Couldn't lock the standalone chat page archive.") }
        defer { _ = POSIX.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard POSIX.fcntl(descriptor, F_SETLKW, &lock) == 0 else {
            throw StandaloneChatStoreError.queryFailed("Couldn't lock the standalone chat page archive.")
        }
        defer { lock.l_type = Int16(F_UNLCK); _ = POSIX.fcntl(descriptor, F_SETLK, &lock) }

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
        _ = POSIX.chmod(url.path, mode_t(0o600))
    }

    package func messages(pageID: String) throws -> [StandaloneChatMessage] {
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

    package func pageAssignmentsByTurnID() throws -> [String: StandaloneChatPage] {
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

    package func searchPages(query: String, limit: Int = 10) throws -> [StandaloneChatPageMatch] {
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

extension StandaloneChat {
    /// The page-store chat this conversation files its pages under: the standalone chat's own, or
    /// a parallel bubble's while it runs.
    var standaloneChatPageScope: String {
        parallelOfChatID == nil ? StandaloneChatManager.defaultChatID : id.uuidString
    }
}

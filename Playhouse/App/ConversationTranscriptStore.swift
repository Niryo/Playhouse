import Foundation
import GRDB

/// Playhouse's own record of a task's provider timeline.
///
/// Codex keeps its full thread history in its app-server, so Playhouse stores
/// only which Codex turns belong to each Codex segment. Claude Code turns are
/// stored here in full (visible messages and activities), so a mixed-provider
/// transcript can be reopened in order without depending on another runtime's
/// private session files. Tasks that never left Codex have no transcript file.
struct ConversationTranscript: Codable, Equatable {
    struct Segment: Codable, Equatable, Identifiable {
        let id: String
        let provider: ConversationProvider
        let startedAt: Date
        /// Codex turns that ran while this segment was active, captured when
        /// the task switched away from Codex. Later Codex turns belong to the
        /// last Codex segment.
        var codexTurnIDs: [String] = []
        /// Selected models keyed by the Codex turn IDs above. Older transcripts
        /// omit this map and render provider-only labels for those turns.
        var codexTurnModelIDs: [String: String] = [:]
        /// Whether the first prompt of this segment already carried the visible
        /// turns this provider had not seen.
        var handoffDelivered = false

        private enum CodingKeys: String, CodingKey { case id, provider, startedAt, codexTurnIDs, codexTurnModelIDs, handoffDelivered }

        init(id: String, provider: ConversationProvider, startedAt: Date, codexTurnIDs: [String] = [], codexTurnModelIDs: [String: String] = [:], handoffDelivered: Bool = false) {
            self.id = id
            self.provider = provider
            self.startedAt = startedAt
            self.codexTurnIDs = codexTurnIDs
            self.codexTurnModelIDs = codexTurnModelIDs
            self.handoffDelivered = handoffDelivered
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            provider = try container.decode(ConversationProvider.self, forKey: .provider)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            codexTurnIDs = try container.decodeIfPresent([String].self, forKey: .codexTurnIDs) ?? []
            codexTurnModelIDs = try container.decodeIfPresent([String: String].self, forKey: .codexTurnModelIDs) ?? [:]
            handoffDelivered = try container.decodeIfPresent(Bool.self, forKey: .handoffDelivered) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(provider, forKey: .provider)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(codexTurnIDs, forKey: .codexTurnIDs)
            try container.encode(codexTurnModelIDs, forKey: .codexTurnModelIDs)
            try container.encode(handoffDelivered, forKey: .handoffDelivered)
        }
    }

    struct Turn: Codable, Equatable, Identifiable {
        let id: String
        let segmentID: String
        var messages: [ConversationMessage] = []
        var activities: [ConversationActivity] = []
    }

    /// What one turn cost, and what ran in it.
    ///
    /// Kept at transcript level rather than inside `Turn` because only Claude
    /// turns have a `Turn` row — Codex keeps its own thread history — and both
    /// providers must appear in the same breakdown.
    struct TurnTokenUsage: Codable, Equatable, Identifiable {
        let id: String
        let provider: ConversationProvider
        let recordedAt: Date
        var usage: ConversationTokenUsage
        var toolLabels: [String] = []
    }

    var version = 1
    var segments: [Segment] = []
    var turns: [Turn] = []
    /// Per-turn token costs, oldest first. Absent in transcripts written before
    /// token tracking existed.
    var tokenUsage: [TurnTokenUsage]?
    /// A provider question that is waiting for user input. The native request
    /// ID is useful only while its provider process is alive; this durable copy
    /// lets the UI restore the question and continue the saved session later.
    var pendingUserInputRequest: ConversationUserInputRequest?
    /// The pending request whose answer a recovery turn is applying. Only the
    /// send holding the task's turn reservation sets it, and history hides the
    /// request only while that reservation is held, so a crash mid-recovery
    /// shows the question again.
    var applyingUserInputRequestID: String?
    struct UserInputRepair: Codable, Equatable {
        let sourceTaskID: UUID
        let request: ConversationUserInputRequest
    }
    /// Retained after answering, so retrying an interrupted two-file repair
    /// cannot resurrect the source's old question.
    var userInputRepairs: [UserInputRepair]?
    /// Private recovery turns. The submitted answers and prompt are never stored
    /// raw; provider activity and diffs for these turns stay hidden.
    var sensitiveTurnIDs: [String]?
    /// Codex turn IDs containing private recovery prompts. Codex-only tasks may
    /// not have a transcript segment to associate these IDs with.
    var sensitiveCodexTurnIDs: [String]?
    /// Codex recovery turns whose assistant responses must stay hidden because
    /// their recovered user input included a secret answer.
    var sensitiveCodexSecretTurnIDs: [String]?
    /// Locally sanitized message copies for private Codex recovery turns. Raw
    /// provider messages can be replaced after restart without losing safe text.
    var sensitiveCodexTurnMessages: [String: [ConversationMessage]]?
    /// Locally observed message times for provider histories that omit them.
    var messageTimestamps: [String: Date]?
    /// Fail-closed marker written before a private recovery prompt is sent.
    var pendingSensitiveUserInputRedaction: Bool?
    /// Every compaction of the Claude session's context, oldest first: what
    /// fired it and how far it shrank the context.
    var contextCompactions: [ContextCompactionEvent]?
    /// Resumed Claude turns whose first call missed the prompt cache, oldest first.
    var promptCacheMisses: [PromptCacheMissEvent]?

    var isEmpty: Bool { segments.isEmpty && turns.isEmpty }

    func turns(in segment: Segment) -> [Turn] {
        turns.filter { $0.segmentID == segment.id }
    }

    func segmentIndex(of segmentID: String) -> Int? {
        segments.firstIndex { $0.id == segmentID }
    }
}

/// Per-task conversation records, kept in one SQLite database beside the task
/// store. The app and the bridge daemon open it concurrently: WAL lets readers
/// proceed during a write, and SQLite serializes writers across processes.
///
/// A task's provider timeline and recovery bookkeeping form one small state
/// row. Turns, messages, activities, and token usage are rows of their own, so
/// recording one streamed message writes that message's row instead of the
/// whole transcript. Image data URLs live in their own column and load only
/// for the messages a caller actually returns.
final class ConversationTranscriptStore {
    /// Which turns a read or mutation loads alongside the task's state. A
    /// mutation sees, and may change or remove, only these turns; turns it did
    /// not load are left as they are.
    struct TurnSelection {
        var includesAllTurns = false
        var includesLatestTurn = false
        var turnIDs: Set<String> = []
        /// Loads the turns holding activities with this background-task ID, and
        /// the turns holding those activities' background agent reports.
        var backgroundTaskID: String?
        /// Loads the turns holding messages with these IDs.
        var messageIDs: Set<String> = []

        static let none = TurnSelection()
        static let all = TurnSelection(includesAllTurns: true)
        static let latest = TurnSelection(includesLatestTurn: true)

        /// The named turn when it exists, and the latest turn as its fallback.
        static func turn(_ id: String?) -> TurnSelection {
            TurnSelection(includesLatestTurn: true, turnIDs: id.map { [$0] } ?? [])
        }
    }

    /// Message ID prefix of the assistant report a completed background agent
    /// leaves in the conversation, followed by the launching activity's ID.
    static let backgroundAgentReportMessagePrefix = "claude-background-agent-result-"
    static let fileName = "Conversations-v1.sqlite"

    let databaseURL: URL
    private let pool: DatabasePool

    private static let storesLock = NSLock()
    private static var stores: [String: ConversationTranscriptStore] = [:]

    /// One open store per database file for the life of the process; opening a
    /// pool per call would reopen connections and rerun the schema check.
    static func open(directory: URL) throws -> ConversationTranscriptStore {
        let url = directory.appendingPathComponent(fileName)
        let key = url.standardizedFileURL.path
        storesLock.lock()
        defer { storesLock.unlock() }
        if let store = stores[key], FileManager.default.fileExists(atPath: key) { return store }
        let store = try ConversationTranscriptStore(databaseURL: url)
        stores[key] = store
        return store
    }

    private init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        // Another process may hold the write lock for a whole turn's bookkeeping.
        configuration.busyMode = .timeout(30)
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        _ = chmod(databaseURL.path, 0o600)
        try pool.write { db in try db.execute(sql: Self.schema) }
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS conversation_state (
        task_id TEXT PRIMARY KEY NOT NULL,
        payload TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS conversation_token_usage (
        task_id TEXT NOT NULL,
        id TEXT NOT NULL,
        position INTEGER NOT NULL,
        payload TEXT NOT NULL,
        PRIMARY KEY (task_id, id)
    );
    CREATE TABLE IF NOT EXISTS conversation_turns (
        task_id TEXT NOT NULL,
        id TEXT NOT NULL,
        segment_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        PRIMARY KEY (task_id, id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS conversation_turns_order ON conversation_turns(task_id, seq);
    CREATE TABLE IF NOT EXISTS conversation_messages (
        task_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        id TEXT NOT NULL,
        position INTEGER NOT NULL,
        payload TEXT NOT NULL,
        image_data_urls TEXT,
        PRIMARY KEY (task_id, turn_id, id)
    );
    CREATE INDEX IF NOT EXISTS conversation_messages_by_id ON conversation_messages(task_id, id);
    CREATE TABLE IF NOT EXISTS conversation_activities (
        task_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        id TEXT NOT NULL,
        position INTEGER NOT NULL,
        background_task_id TEXT,
        payload TEXT NOT NULL,
        PRIMARY KEY (task_id, turn_id, id)
    );
    CREATE INDEX IF NOT EXISTS conversation_activities_by_background_task
        ON conversation_activities(task_id, background_task_id) WHERE background_task_id IS NOT NULL;
    """

    /// The task's state, token usage, and segments, without any turns.
    func readState(_ taskID: UUID) throws -> ConversationTranscript {
        try read(taskID, turns: .none, includeImages: false)
    }

    func read(_ taskID: UUID, turns selection: TurnSelection, includeImages: Bool) throws -> ConversationTranscript {
        try pool.read { db in
            try Self.load(db, taskID: taskID, selection: selection, includeImages: includeImages)
        }
    }

    /// Applies `mutation` to the selected turns in one transaction and writes
    /// only the rows it changed. Image data is not loaded for mutation: a
    /// message saved without images keeps any images its row already stores.
    @discardableResult
    func mutate<T>(_ taskID: UUID, turns selection: TurnSelection, _ mutation: (inout ConversationTranscript) throws -> T) throws -> T {
        try pool.write { db in
            var transcript = try Self.load(db, taskID: taskID, selection: selection, includeImages: false)
            let original = transcript
            let result = try mutation(&transcript)
            try Self.save(db, taskID: taskID, from: original, to: transcript)
            return result
        }
    }

    /// Stored image data URLs for the given messages, keyed by message ID and
    /// then by the turn holding it. Message IDs are unique only within a turn.
    func imageDataURLs(_ taskID: UUID, messageIDs: Set<String>) throws -> [String: [String: [String]]] {
        guard !messageIDs.isEmpty else { return [:] }
        let ids = Array(messageIDs)
        return try pool.read { db in
            var result: [String: [String: [String]]] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT turn_id, id, image_data_urls FROM conversation_messages WHERE task_id = ? AND image_data_urls IS NOT NULL AND id IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments([taskID.uuidString] + chunk)
                )
                for row in rows {
                    result[row["id"], default: [:]][row["turn_id"]] = try Self.decode([String].self, row["image_data_urls"])
                }
            }
            return result
        }
    }

    /// Which of the given messages have stored images, as the turns holding each,
    /// read without touching the image data itself.
    func turnsWithImages(_ taskID: UUID, messageIDs: Set<String>) throws -> [String: Set<String>] {
        guard !messageIDs.isEmpty else { return [:] }
        let ids = Array(messageIDs)
        return try pool.read { db in
            var result: [String: Set<String>] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT turn_id, id FROM conversation_messages WHERE task_id = ? AND image_data_urls IS NOT NULL AND id IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments([taskID.uuidString] + chunk)
                )
                for row in rows {
                    result[row["id"], default: []].insert(row["turn_id"])
                }
            }
            return result
        }
    }

    /// The task's turns in order with their message IDs, without message bodies.
    struct Outline {
        struct Turn {
            let id: String
            let segmentID: String
            let messageIDs: [String]
            let userTexts: [String]
        }
        var turns: [Turn]
        /// Whether any stored message carries its own timeline position, or any
        /// activity is a context compaction. Either one can reorder composed
        /// history, so a page cannot be read by stored position alone.
        var hasPositionedElements: Bool
    }

    func outline(_ taskID: UUID) throws -> Outline {
        let key = taskID.uuidString
        return try pool.read { db in
            var messageIDs: [String: [String]] = [:]
            var userTexts: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT turn_id, id, json_extract(payload, '$.role') AS role, \
                CASE WHEN json_extract(payload, '$.role') = 'user' THEN json_extract(payload, '$.text') END AS user_text \
                FROM conversation_messages WHERE task_id = ? ORDER BY position
                """,
                arguments: [key]
            ) {
                let turnID: String = row["turn_id"]
                messageIDs[turnID, default: []].append(row["id"])
                if let text: String = row["user_text"] { userTexts[turnID, default: []].append(text) }
            }
            let turns = try Row.fetchAll(db, sql: "SELECT id, segment_id FROM conversation_turns WHERE task_id = ? ORDER BY seq", arguments: [key]).map { row in
                let id: String = row["id"]
                return Outline.Turn(id: id, segmentID: row["segment_id"], messageIDs: messageIDs[id] ?? [], userTexts: userTexts[id] ?? [])
            }
            let positioned = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(SELECT 1 FROM conversation_messages WHERE task_id = ? AND json_extract(payload, '$.timelineOrder') IS NOT NULL)
                    OR EXISTS(SELECT 1 FROM conversation_activities WHERE task_id = ? AND json_extract(payload, '$.isContextCompaction') = 1)
                """,
                arguments: [key, key]
            ) ?? true
            return Outline(turns: turns, hasPositionedElements: positioned)
        }
    }

    /// The model of the newest assistant message that names one, among the turns of the given
    /// segments. Turns are searched newest first, a query each, so a long conversation is not
    /// decoded to find it.
    func latestAssistantModelID(_ taskID: UUID, segmentIDs: Set<String>) throws -> String? {
        guard !segmentIDs.isEmpty else { return nil }
        return try pool.read { db in
            let key = taskID.uuidString
            let turns = try Row.fetchAll(db, sql: "SELECT id, segment_id FROM conversation_turns WHERE task_id = ? ORDER BY seq DESC", arguments: [key])
            for turn in turns where segmentIDs.contains(turn["segment_id"]) {
                let modelID = try String.fetchOne(
                    db,
                    sql: """
                    SELECT json_extract(payload, '$.modelID') FROM conversation_messages
                    WHERE task_id = ? AND turn_id = ? AND json_extract(payload, '$.role') = 'assistant'
                        AND json_extract(payload, '$.modelID') IS NOT NULL
                    ORDER BY position DESC LIMIT 1
                    """,
                    arguments: [key, turn["id"] as String]
                )
                if let modelID { return modelID }
            }
            return nil
        }
    }

    /// Subagent activities held by the given turns, in turn and activity order.
    func subagentActivities(_ taskID: UUID, turnIDs: [String]) throws -> [ConversationActivity] {
        guard !turnIDs.isEmpty else { return [] }
        return try pool.read { db in
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT a.payload FROM conversation_activities a
                JOIN conversation_turns t ON t.task_id = a.task_id AND t.id = a.turn_id
                WHERE a.task_id = ? AND a.turn_id IN (\(Self.placeholders(turnIDs.count))) AND json_extract(a.payload, '$.childThreadID') IS NOT NULL
                ORDER BY t.seq, a.position
                """,
                arguments: StatementArguments([taskID.uuidString] + turnIDs)
            )
            return try rows.map { try Self.decode(ConversationActivity.self, $0) }
        }
    }

    /// Moves a misplaced pending question to the task that owns its thread in one
    /// transaction. The receipt left on the destination keeps a retried repair
    /// from resurrecting a question that was already answered.
    func reassignPendingUserInput(from sourceID: UUID, to targetID: UUID, threadID: String) throws -> ConversationUserInputRequest {
        try pool.write { db in
            var source = try Self.load(db, taskID: sourceID, selection: .none, includeImages: false)
            var target = try Self.load(db, taskID: targetID, selection: .none, includeImages: false)
            let originalSource = source
            let originalTarget = target
            guard let request = source.pendingUserInputRequest else {
                if let repaired = target.pendingUserInputRequest, repaired.threadID == threadID { return repaired }
                throw BridgeCommandError(code: "not_found", message: "The source task has no pending question to repair.")
            }
            guard request.threadID == threadID else {
                throw BridgeCommandError(code: "invalid_transition", message: "The source question does not belong to the destination conversation.")
            }
            let receipt = ConversationTranscript.UserInputRepair(sourceTaskID: sourceID, request: request)
            guard target.pendingUserInputRequest != nil || !(target.userInputRepairs ?? []).contains(receipt) else {
                throw BridgeCommandError(code: "invalid_transition", message: "This question was already repaired and is no longer pending.")
            }
            guard target.pendingUserInputRequest == nil || target.pendingUserInputRequest == request else {
                throw BridgeCommandError(code: "invalid_transition", message: "The destination conversation already has a different pending question.")
            }
            target.pendingUserInputRequest = request
            if !(target.userInputRepairs ?? []).contains(receipt) {
                target.userInputRepairs = (target.userInputRepairs ?? []) + [receipt]
            }
            source.pendingUserInputRequest = nil
            try Self.save(db, taskID: targetID, from: originalTarget, to: target)
            try Self.save(db, taskID: sourceID, from: originalSource, to: source)
            return request
        }
    }

    func remove(_ taskID: UUID) throws {
        try pool.write { db in
            for table in ["conversation_state", "conversation_token_usage", "conversation_turns", "conversation_messages", "conversation_activities"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE task_id = ?", arguments: [taskID.uuidString])
            }
        }
    }

    // MARK: - Rows

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ payload: String) throws -> T {
        try decoder.decode(type, from: Data(payload.utf8))
    }

    private static func load(_ db: Database, taskID: UUID, selection: TurnSelection, includeImages: Bool) throws -> ConversationTranscript {
        let key = taskID.uuidString
        var transcript = ConversationTranscript()
        if let payload = try String.fetchOne(db, sql: "SELECT payload FROM conversation_state WHERE task_id = ?", arguments: [key]) {
            transcript = try decode(ConversationTranscript.self, payload)
        }
        transcript.turns = []
        let usage = try String.fetchAll(db, sql: "SELECT payload FROM conversation_token_usage WHERE task_id = ? ORDER BY position", arguments: [key])
        transcript.tokenUsage = usage.isEmpty ? nil : try usage.map { try decode(ConversationTranscript.TurnTokenUsage.self, $0) }

        let turnRows: [Row]
        let turnFilter: (sql: String, arguments: [String])
        if selection.includesAllTurns {
            turnRows = try Row.fetchAll(db, sql: "SELECT id, segment_id FROM conversation_turns WHERE task_id = ? ORDER BY seq", arguments: [key])
            turnFilter = ("", [])
        } else {
            var ids = selection.turnIDs
            var messageIDs = selection.messageIDs
            if selection.includesLatestTurn,
               let latest = try String.fetchOne(db, sql: "SELECT id FROM conversation_turns WHERE task_id = ? ORDER BY seq DESC LIMIT 1", arguments: [key]) {
                ids.insert(latest)
            }
            if let backgroundTaskID = selection.backgroundTaskID {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT turn_id, id FROM conversation_activities WHERE task_id = ? AND background_task_id = ?",
                    arguments: [key, backgroundTaskID]
                )
                for row in rows {
                    ids.insert(row["turn_id"])
                    messageIDs.insert(backgroundAgentReportMessagePrefix + (row["id"] as String))
                }
            }
            if !messageIDs.isEmpty {
                let messageIDList = Array(messageIDs)
                ids.formUnion(try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT turn_id FROM conversation_messages WHERE task_id = ? AND id IN (\(placeholders(messageIDList.count)))",
                    arguments: StatementArguments([key] + messageIDList)
                ))
            }
            guard !ids.isEmpty else { return transcript }
            let idList = Array(ids)
            turnRows = try Row.fetchAll(
                db,
                sql: "SELECT id, segment_id FROM conversation_turns WHERE task_id = ? AND id IN (\(placeholders(idList.count))) ORDER BY seq",
                arguments: StatementArguments([key] + idList)
            )
            turnFilter = (" AND turn_id IN (\(placeholders(idList.count)))", idList)
        }
        guard !turnRows.isEmpty else { return transcript }

        var messagesByTurn: [String: [ConversationMessage]] = [:]
        let imageColumn = includeImages ? "image_data_urls" : "NULL AS image_data_urls"
        for row in try Row.fetchAll(
            db,
            sql: "SELECT turn_id, payload, \(imageColumn) FROM conversation_messages WHERE task_id = ?\(turnFilter.sql) ORDER BY position",
            arguments: StatementArguments([key] + turnFilter.arguments)
        ) {
            var message = try decode(ConversationMessage.self, row["payload"])
            if let images: String = row["image_data_urls"] {
                message.imageDataURLs = try decode([String].self, images)
            }
            messagesByTurn[row["turn_id"], default: []].append(message)
        }
        var activitiesByTurn: [String: [ConversationActivity]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT turn_id, payload FROM conversation_activities WHERE task_id = ?\(turnFilter.sql) ORDER BY position",
            arguments: StatementArguments([key] + turnFilter.arguments)
        ) {
            activitiesByTurn[row["turn_id"], default: []].append(try decode(ConversationActivity.self, row["payload"]))
        }
        transcript.turns = turnRows.map { row in
            let id: String = row["id"]
            return ConversationTranscript.Turn(
                id: id,
                segmentID: row["segment_id"],
                messages: messagesByTurn[id] ?? [],
                activities: activitiesByTurn[id] ?? []
            )
        }
        return transcript
    }

    private static func save(_ db: Database, taskID: UUID, from original: ConversationTranscript, to transcript: ConversationTranscript) throws {
        let key = taskID.uuidString
        var originalState = original
        originalState.turns = []
        originalState.tokenUsage = nil
        var state = transcript
        state.turns = []
        state.tokenUsage = nil
        if state != originalState {
            try db.execute(
                sql: "INSERT INTO conversation_state (task_id, payload) VALUES (?, ?) ON CONFLICT(task_id) DO UPDATE SET payload = excluded.payload",
                arguments: [key, try json(state)]
            )
        }

        let originalUsage = original.tokenUsage ?? []
        let usage = transcript.tokenUsage ?? []
        if usage != originalUsage {
            let usageIDs = Set(usage.map(\.id))
            for row in originalUsage where !usageIDs.contains(row.id) {
                try db.execute(sql: "DELETE FROM conversation_token_usage WHERE task_id = ? AND id = ?", arguments: [key, row.id])
            }
            let previous = Dictionary(originalUsage.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
            for (position, row) in usage.enumerated() {
                if let (oldPosition, old) = previous[row.id], oldPosition == position, old == row { continue }
                try db.execute(
                    sql: """
                    INSERT INTO conversation_token_usage (task_id, id, position, payload) VALUES (?, ?, ?, ?)
                    ON CONFLICT(task_id, id) DO UPDATE SET position = excluded.position, payload = excluded.payload
                    """,
                    arguments: [key, row.id, position, try json(row)]
                )
            }
        }

        let originalTurns = Dictionary(original.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let turnIDs = Set(transcript.turns.map(\.id))
        for turn in original.turns where !turnIDs.contains(turn.id) {
            for table in ["conversation_turns", "conversation_messages", "conversation_activities"] {
                let column = table == "conversation_turns" ? "id" : "turn_id"
                try db.execute(sql: "DELETE FROM \(table) WHERE task_id = ? AND \(column) = ?", arguments: [key, turn.id])
            }
        }
        var nextSeq: Int?
        for turn in transcript.turns {
            let previous = originalTurns[turn.id]
            if let previous {
                if previous.segmentID != turn.segmentID {
                    try db.execute(
                        sql: "UPDATE conversation_turns SET segment_id = ? WHERE task_id = ? AND id = ?",
                        arguments: [turn.segmentID, key, turn.id]
                    )
                }
            } else {
                let seq = try nextSeq ?? (Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM conversation_turns WHERE task_id = ?", arguments: [key]) ?? 1)
                nextSeq = seq + 1
                try db.execute(
                    sql: """
                    INSERT INTO conversation_turns (task_id, id, segment_id, seq) VALUES (?, ?, ?, ?)
                    ON CONFLICT(task_id, id) DO UPDATE SET segment_id = excluded.segment_id
                    """,
                    arguments: [key, turn.id, turn.segmentID, seq]
                )
            }
            try saveMessages(db, key: key, turnID: turn.id, from: previous?.messages ?? [], to: turn.messages)
            try saveActivities(db, key: key, turnID: turn.id, from: previous?.activities ?? [], to: turn.activities)
        }
    }

    private static func saveMessages(_ db: Database, key: String, turnID: String, from original: [ConversationMessage], to messages: [ConversationMessage]) throws {
        let ids = Set(messages.map(\.id))
        for message in original where !ids.contains(message.id) {
            try db.execute(
                sql: "DELETE FROM conversation_messages WHERE task_id = ? AND turn_id = ? AND id = ?",
                arguments: [key, turnID, message.id]
            )
        }
        let previous = Dictionary(original.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
        for (position, message) in messages.enumerated() {
            if let (oldPosition, old) = previous[message.id], oldPosition == position, old == message { continue }
            var payload = message
            payload.imageDataURLs = []
            payload.imagesDeferred = nil
            try db.execute(
                sql: """
                INSERT INTO conversation_messages (task_id, turn_id, id, position, payload, image_data_urls) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(task_id, turn_id, id) DO UPDATE SET
                    position = excluded.position,
                    payload = excluded.payload,
                    image_data_urls = COALESCE(excluded.image_data_urls, conversation_messages.image_data_urls)
                """,
                arguments: [key, turnID, message.id, position, try json(payload), message.imageDataURLs.isEmpty ? nil : try json(message.imageDataURLs)]
            )
        }
    }

    private static func saveActivities(_ db: Database, key: String, turnID: String, from original: [ConversationActivity], to activities: [ConversationActivity]) throws {
        let ids = Set(activities.map(\.id))
        for activity in original where !ids.contains(activity.id) {
            try db.execute(
                sql: "DELETE FROM conversation_activities WHERE task_id = ? AND turn_id = ? AND id = ?",
                arguments: [key, turnID, activity.id]
            )
        }
        let previous = Dictionary(original.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { first, _ in first })
        for (position, activity) in activities.enumerated() {
            if let (oldPosition, old) = previous[activity.id], oldPosition == position, old == activity { continue }
            try db.execute(
                sql: """
                INSERT INTO conversation_activities (task_id, turn_id, id, position, background_task_id, payload) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(task_id, turn_id, id) DO UPDATE SET
                    position = excluded.position,
                    background_task_id = excluded.background_task_id,
                    payload = excluded.payload
                """,
                arguments: [key, turnID, activity.id, position, activity.backgroundTaskID, try json(activity)]
            )
        }
    }
}

/// Builds the labeled context a provider receives on its first prompt after a
/// switch. Only visible user and assistant text crosses providers; native tool
/// history and hidden reasoning stay with the runtime that produced them.
enum ConversationHandoff {
    static let openTag = "<playhouse-handoff-context>"
    static let closeTag = "</playhouse-handoff-context>"
    private static let characterLimit = 40_000

    static let defaultPreamble = "This Playhouse task continued with another assistant while you were not active. These are the visible turns you have not seen, provided as context. Tool history and hidden reasoning are not included; inspect the workspace for the current state of files."
    /// Standalone chat pages are separate conversations, so their context block says so instead
    /// of describing a provider handoff.
    static let chatPagePreamble = "Earlier turns of this standalone chat, provided as context. This chat is split into pages and each page is its own conversation: only the pages below are in scope for this turn."

    static func context(for provider: ConversationProvider, messages: [ConversationMessage], preamble: String? = nil) -> String? {
        // A turn whose answer was only recorded as commentary still hands off its
        // last commentary, so a misclassified answer is never silently dropped.
        let answeredTurns = Set(messages.compactMap { $0.role == .assistant && $0.phase != "commentary" ? $0.turnID : nil })
        let lastCommentaryIDs = Set(Dictionary(
            messages.compactMap { message in
                message.phase == "commentary" ? message.turnID.map { ($0, message.id) } : nil
            },
            uniquingKeysWith: { _, last in last }
        ).filter { !answeredTurns.contains($0.key) }.values)
        let lines = messages.compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, message.phase != "commentary" || lastCommentaryIDs.contains(message.id) else { return nil }
            let speaker = message.role == .user ? "User" : (message.provider ?? .codex).displayName
            return "\(speaker): \(text)"
        }
        guard !lines.isEmpty else { return nil }
        var transcript = lines.joined(separator: "\n\n")
        if transcript.count > characterLimit {
            transcript = "[Earlier turns omitted]\n\n" + String(transcript.suffix(characterLimit))
        }
        return """
        \(openTag)
        \(preamble ?? defaultPreamble)

        \(transcript)
        \(closeTag)
        """
    }

    static func prompt(_ text: String, context: String?) -> String {
        guard let context else { return text }
        return text.isEmpty ? context : "\(context)\n\n\(text)"
    }

    /// Removes a handoff block that a native transcript stored with the prompt.
    static func stripContext(from text: String) -> String {
        guard text.hasPrefix(openTag), let close = text.range(of: closeTag) else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

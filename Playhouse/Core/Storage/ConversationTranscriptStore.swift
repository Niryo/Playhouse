import Foundation
import GRDB

/// Playhouse's own record of a task's conversation: the transcript it shows.
///
/// Every turn of every provider is stored here in full, as it streamed (messages,
/// activities, usage and the latest diff), so a conversation and any page of it
/// reopen from this store alone. Neither Codex's app-server thread nor Claude
/// Code's session files are read back to show a conversation; the provider's
/// thread or session ID only resumes the agent's own context.
package struct ConversationTranscript: Codable, Equatable {
    package struct Segment: Codable, Equatable, Identifiable {
        package let id: String
        package let provider: ConversationProvider
        package let startedAt: Date
        /// Codex's own IDs for the turns that ran in this segment: resume metadata
        /// for the app-server thread, never a source of the transcript.
        package var codexTurnIDs: [String] = []
        /// Selected models keyed by the Codex turn IDs above. Older transcripts
        /// omit this map and render provider-only labels for those turns.
        package var codexTurnModelIDs: [String: String] = [:]
        /// Whether the first prompt of this segment already carried the visible
        /// turns this provider had not seen.
        package var handoffDelivered = false

        private enum CodingKeys: String, CodingKey { case id, provider, startedAt, codexTurnIDs, codexTurnModelIDs, handoffDelivered }

        package init(id: String, provider: ConversationProvider, startedAt: Date, codexTurnIDs: [String] = [], codexTurnModelIDs: [String: String] = [:], handoffDelivered: Bool = false) {
            self.id = id
            self.provider = provider
            self.startedAt = startedAt
            self.codexTurnIDs = codexTurnIDs
            self.codexTurnModelIDs = codexTurnModelIDs
            self.handoffDelivered = handoffDelivered
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            provider = try container.decode(ConversationProvider.self, forKey: .provider)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            codexTurnIDs = try container.decodeIfPresent([String].self, forKey: .codexTurnIDs) ?? []
            codexTurnModelIDs = try container.decodeIfPresent([String: String].self, forKey: .codexTurnModelIDs) ?? [:]
            handoffDelivered = try container.decodeIfPresent(Bool.self, forKey: .handoffDelivered) ?? false
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(provider, forKey: .provider)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(codexTurnIDs, forKey: .codexTurnIDs)
            try container.encode(codexTurnModelIDs, forKey: .codexTurnModelIDs)
            try container.encode(handoffDelivered, forKey: .handoffDelivered)
        }
    }

    package struct Turn: Codable, Equatable, Identifiable {
        package let id: String
        package let segmentID: String
        package var messages: [ConversationMessage] = []
        package var activities: [ConversationActivity] = []

        package init(id: String, segmentID: String, messages: [ConversationMessage] = [], activities: [ConversationActivity] = []) {
            self.id = id
            self.segmentID = segmentID
            self.messages = messages
            self.activities = activities
        }
    }

    /// What one turn cost, and what ran in it.
    ///
    /// Kept at transcript level rather than inside `Turn` so usage reported for
    /// a turn with no recorded messages, such as a compaction, still appears in
    /// the breakdown.
    package struct TurnTokenUsage: Codable, Equatable, Identifiable {
        package let id: String
        package let provider: ConversationProvider
        package let recordedAt: Date
        package var usage: ConversationTokenUsage
        package var toolLabels: [String] = []

        package init(id: String, provider: ConversationProvider, recordedAt: Date, usage: ConversationTokenUsage, toolLabels: [String] = []) {
            self.id = id
            self.provider = provider
            self.recordedAt = recordedAt
            self.usage = usage
            self.toolLabels = toolLabels
        }
    }

    package var version = 1
    package var segments: [Segment] = []
    package var turns: [Turn] = []
    /// Per-turn token costs, oldest first. Absent in transcripts written before
    /// token tracking existed.
    package var tokenUsage: [TurnTokenUsage]?
    /// A provider question that is waiting for user input. The native request
    /// ID is useful only while its provider process is alive; this durable copy
    /// lets the UI restore the question and continue the saved session later.
    package var pendingUserInputRequest: ConversationUserInputRequest?
    /// The pending request whose answer a recovery turn is applying. Only the
    /// send holding the task's turn reservation sets it, and history hides the
    /// request only while that reservation is held, so a crash mid-recovery
    /// shows the question again.
    package var applyingUserInputRequestID: String?
    package struct UserInputRepair: Codable, Equatable {
        package let sourceTaskID: UUID
        package let request: ConversationUserInputRequest

        package init(sourceTaskID: UUID, request: ConversationUserInputRequest) {
            self.sourceTaskID = sourceTaskID
            self.request = request
        }
    }
    /// Retained after answering, so retrying an interrupted two-file repair
    /// cannot resurrect the source's old question.
    package var userInputRepairs: [UserInputRepair]?
    /// The latest turn's working-tree diff, as its provider last reported it.
    package var latestDiff: ConversationTurnDiff?
    /// Every compaction of the Claude session's context, oldest first: what
    /// fired it and how far it shrank the context.
    package var contextCompactions: [ContextCompactionEvent]?
    /// Resumed Claude turns whose first call missed the prompt cache, oldest first.
    package var promptCacheMisses: [PromptCacheMissEvent]?
    /// Turns sent in Plan mode, oldest first: each one's final answer is a plan. Absent
    /// in transcripts written before turns recorded their mode.
    package var planTurnIDs: [String]?
    /// Turns an optimized follow-up started in a fresh, seeded provider session.
    package var freshSessionTurnIDs: [String]?

    package var isEmpty: Bool { segments.isEmpty && turns.isEmpty }

    package func turns(in segment: Segment) -> [Turn] {
        turns.filter { $0.segmentID == segment.id }
    }

    package func segmentIndex(of segmentID: String) -> Int? {
        segments.firstIndex { $0.id == segmentID }
    }

    package init(version: Int = 1, segments: [Segment] = [], turns: [Turn] = [], tokenUsage: [TurnTokenUsage]? = nil, pendingUserInputRequest: ConversationUserInputRequest? = nil, applyingUserInputRequestID: String? = nil, userInputRepairs: [UserInputRepair]? = nil, latestDiff: ConversationTurnDiff? = nil, contextCompactions: [ContextCompactionEvent]? = nil, promptCacheMisses: [PromptCacheMissEvent]? = nil, planTurnIDs: [String]? = nil, freshSessionTurnIDs: [String]? = nil) {
        self.version = version
        self.segments = segments
        self.turns = turns
        self.tokenUsage = tokenUsage
        self.pendingUserInputRequest = pendingUserInputRequest
        self.applyingUserInputRequestID = applyingUserInputRequestID
        self.userInputRepairs = userInputRepairs
        self.latestDiff = latestDiff
        self.contextCompactions = contextCompactions
        self.promptCacheMisses = promptCacheMisses
        self.planTurnIDs = planTurnIDs
        self.freshSessionTurnIDs = freshSessionTurnIDs
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
package final class ConversationTranscriptStore {
    /// Which turns a read or mutation loads alongside the task's state. A
    /// mutation sees, and may change or remove, only these turns; turns it did
    /// not load are left as they are.
    package struct TurnSelection {
        package var includesAllTurns = false
        package var includesLatestTurn = false
        package var turnIDs: Set<String> = []
        /// Loads the turns holding activities with this background-task ID, and
        /// the turns holding those activities' background agent reports.
        package var backgroundTaskID: String?
        /// Loads the turns holding messages with these IDs.
        package var messageIDs: Set<String> = []

        package static let none = TurnSelection()
        package static let all = TurnSelection(includesAllTurns: true)
        package static let latest = TurnSelection(includesLatestTurn: true)

        /// The named turn when it exists, and the latest turn as its fallback.
        package static func turn(_ id: String?) -> TurnSelection {
            TurnSelection(includesLatestTurn: true, turnIDs: id.map { [$0] } ?? [])
        }

        package init(includesAllTurns: Bool = false, includesLatestTurn: Bool = false, turnIDs: Set<String> = [], backgroundTaskID: String? = nil, messageIDs: Set<String> = []) {
            self.includesAllTurns = includesAllTurns
            self.includesLatestTurn = includesLatestTurn
            self.turnIDs = turnIDs
            self.backgroundTaskID = backgroundTaskID
            self.messageIDs = messageIDs
        }
    }

    /// Message ID prefix of the assistant report a completed background agent
    /// leaves in the conversation, followed by the launching activity's ID.
    package static let backgroundAgentReportMessagePrefix = "claude-background-agent-result-"
    package static let fileName = "Conversations-v1.sqlite"

    package let databaseURL: URL
    private let pool: DatabasePool

    private static let storesLock = NSLock()
    private static var stores: [String: ConversationTranscriptStore] = [:]

    /// One open store per database file for the life of the process; opening a
    /// pool per call would reopen connections and rerun the schema check.
    package static func open(directory: URL) throws -> ConversationTranscriptStore {
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
    package func readState(_ taskID: UUID) throws -> ConversationTranscript {
        try read(taskID, turns: .none, includeImages: false)
    }

    package func read(_ taskID: UUID, turns selection: TurnSelection, includeImages: Bool) throws -> ConversationTranscript {
        try pool.read { db in
            try Self.load(db, taskID: taskID, selection: selection, includeImages: includeImages)
        }
    }

    /// Applies `mutation` to the selected turns in one transaction and writes
    /// only the rows it changed. Image data is not loaded for mutation: a
    /// message saved without images keeps any images its row already stores.
    ///
    /// A task removed in this process takes no more writes: the turn its deletion stopped may
    /// still be winding down, and its last events must not bring the transcript back.
    @discardableResult
    package func mutate<T>(_ taskID: UUID, turns selection: TurnSelection, _ mutation: (inout ConversationTranscript) throws -> T) throws -> T {
        try pool.write { db in
            var transcript = try Self.load(db, taskID: taskID, selection: selection, includeImages: false)
            let original = transcript
            let result = try mutation(&transcript)
            if !Self.isRemoved(taskID) {
                try Self.save(db, taskID: taskID, from: original, to: transcript)
            }
            return result
        }
    }

    private static let removedTaskIDsLock = NSLock()
    private static var removedTaskIDs: Set<UUID> = []

    package static func isRemoved(_ taskID: UUID) -> Bool {
        removedTaskIDsLock.withLock { removedTaskIDs.contains(taskID) }
    }

    /// Stored image data URLs for the given messages, keyed by message ID and
    /// then by the turn holding it. Message IDs are unique only within a turn.
    package func imageDataURLs(_ taskID: UUID, messageIDs: Set<String>) throws -> [String: [String: [String]]] {
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
    package func turnsWithImages(_ taskID: UUID, messageIDs: Set<String>) throws -> [String: Set<String>] {
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
    package struct Outline {
        package struct Turn {
            package let id: String
            package let segmentID: String
            package let messageIDs: [String]
            package let userTexts: [String]

            package init(id: String, segmentID: String, messageIDs: [String], userTexts: [String]) {
                self.id = id
                self.segmentID = segmentID
                self.messageIDs = messageIDs
                self.userTexts = userTexts
            }
        }
        package var turns: [Turn]
        /// Whether any stored message carries its own timeline position, or any
        /// activity is a context compaction. Either one can reorder composed
        /// history, so a page cannot be read by stored position alone.
        package var hasPositionedElements: Bool

        package init(turns: [Turn], hasPositionedElements: Bool) {
            self.turns = turns
            self.hasPositionedElements = hasPositionedElements
        }
    }

    package func outline(_ taskID: UUID) throws -> Outline {
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
    package func latestAssistantModelID(_ taskID: UUID, segmentIDs: Set<String>) throws -> String? {
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
    package func subagentActivities(_ taskID: UUID, turnIDs: [String]) throws -> [ConversationActivity] {
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
    package func reassignPendingUserInput(from sourceID: UUID, to targetID: UUID, threadID: String) throws -> ConversationUserInputRequest {
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

    /// Moves every turn of `sourceID` into `targetID` right after the target's `afterTurnID`, or
    /// before its first turn when that is nil, in one transaction, and removes what is left of
    /// the source. Moved turns join the target's neighbouring segment: history orders messages
    /// by segment first, so a segment of their own would show them after the target's turns.
    /// Running it again after the move finds no turns and only removes the source.
    package func moveTurns(from sourceID: UUID, into targetID: UUID, afterTurnID: String?) throws {
        let source = sourceID.uuidString
        let target = targetID.uuidString
        try pool.write { db in
            let turnIDs = try String.fetchAll(db, sql: "SELECT id FROM conversation_turns WHERE task_id = ? ORDER BY seq", arguments: [source])
            guard !turnIDs.isEmpty else { return }
            let insertSeq: Int
            if let afterTurnID {
                guard let seq = try Int.fetchOne(db, sql: "SELECT seq FROM conversation_turns WHERE task_id = ? AND id = ?", arguments: [target, afterTurnID]) else {
                    throw BridgeCommandError(code: "not_found", message: "The turn to insert after is not in this conversation.")
                }
                insertSeq = seq + 1
            } else {
                insertSeq = try Int.fetchOne(db, sql: "SELECT MIN(seq) FROM conversation_turns WHERE task_id = ?", arguments: [target]) ?? 1
            }
            let segmentID = try String.fetchOne(
                db, sql: "SELECT segment_id FROM conversation_turns WHERE task_id = ? AND seq >= ? ORDER BY seq LIMIT 1", arguments: [target, insertSeq]
            ) ?? String.fetchOne(
                db, sql: "SELECT segment_id FROM conversation_turns WHERE task_id = ? AND seq < ? ORDER BY seq DESC LIMIT 1", arguments: [target, insertSeq]
            )
            if segmentID == nil {
                // The target has no turns yet, so the moved turns keep their own segments.
                var targetState = try Self.load(db, taskID: targetID, selection: .none, includeImages: false)
                let originalTarget = targetState
                let sourceState = try Self.load(db, taskID: sourceID, selection: .none, includeImages: false)
                let known = Set(targetState.segments.map(\.id))
                targetState.segments += sourceState.segments.filter { !known.contains($0.id) }
                try Self.save(db, taskID: targetID, from: originalTarget, to: targetState)
            }
            // Two passes through negative values keep (task_id, seq) unique while the later turns shift.
            try db.execute(
                sql: "UPDATE conversation_turns SET seq = -(seq + ?) WHERE task_id = ? AND seq >= ?",
                arguments: [turnIDs.count, target, insertSeq]
            )
            try db.execute(sql: "UPDATE conversation_turns SET seq = -seq WHERE task_id = ? AND seq < 0", arguments: [target])
            for (offset, turnID) in turnIDs.enumerated() {
                if let segmentID {
                    try db.execute(
                        sql: "UPDATE conversation_turns SET task_id = ?, seq = ?, segment_id = ? WHERE task_id = ? AND id = ?",
                        arguments: [target, insertSeq + offset, segmentID, source, turnID]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE conversation_turns SET task_id = ?, seq = ? WHERE task_id = ? AND id = ?",
                        arguments: [target, insertSeq + offset, source, turnID]
                    )
                }
            }
            for table in ["conversation_messages", "conversation_activities"] {
                try db.execute(sql: "UPDATE \(table) SET task_id = ? WHERE task_id = ?", arguments: [target, source])
            }
            let usagePosition = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM conversation_token_usage WHERE task_id = ?", arguments: [target]) ?? 0
            try db.execute(
                sql: "UPDATE OR IGNORE conversation_token_usage SET task_id = ?, position = position + ? WHERE task_id = ?",
                arguments: [target, usagePosition, source]
            )
        }
        try remove(sourceID)
    }

    package func remove(_ taskID: UUID) throws {
        _ = Self.removedTaskIDsLock.withLock { Self.removedTaskIDs.insert(taskID) }
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
package enum ConversationHandoff {
    package static let openTag = "<playhouse-handoff-context>"
    package static let closeTag = "</playhouse-handoff-context>"
    private static let characterLimit = 40_000

    package static let defaultPreamble = "This Playhouse task continued with another assistant while you were not active. These are the visible turns you have not seen, provided as context. Tool history and hidden reasoning are not included; inspect the workspace for the current state of files."
    /// Standalone chat pages are separate conversations, so their context block says so instead
    /// of describing a provider handoff.
    package static let chatPagePreamble = "Earlier turns of this standalone chat, provided as context. This chat is split into pages and each page is its own conversation: only the pages below are in scope for this turn."

    package static func context(for provider: ConversationProvider, messages: [ConversationMessage], preamble: String? = nil) -> String? {
        guard let transcript = transcript(messages: messages) else { return nil }
        return """
        \(openTag)
        \(preamble ?? defaultPreamble)

        \(transcript)
        \(closeTag)
        """
    }

    /// One standalone chat page and its archived turns, as a chat page context block shows it.
    package struct ChatPage {
        package let page: StandaloneChatPage
        package let messages: [ConversationMessage]

        package init(page: StandaloneChatPage, messages: [ConversationMessage]) {
            self.page = page
            self.messages = messages
        }
    }

    /// How many earlier pages a fresh page session is told about, newest first.
    package static let recentChatPageLimit = 8
    /// Each side of the current page's latest exchange is cut to this many characters. A
    /// follow-up usually only needs the last answer's gist, and anything more is one
    /// `chat page read` away, so the excerpt stays small however long the page grows.
    package static let chatPageExcerptCharacterLimit = 1_200

    /// The context a standalone chat page session receives. A fresh page session gets only
    /// metadata: the current page's ID and title with a short excerpt of its latest exchange,
    /// and the IDs and titles of recent pages, so the agent loads a page with `chat page read`
    /// only when the user's message actually continues it. Pages the user explicitly attached
    /// to this turn (`fullPages`) still travel whole, under a Playhouse page marker rather
    /// than a line that reads as something the user typed.
    /// `currentIsUserNewPage` says the user started the current page with New page for this
    /// message, so the agent treats it as a new topic and names the page.
    package static func chatPageContext(
        current: ChatPage?, currentIsUserNewPage: Bool = false, recentPages: [StandaloneChatPage], fullPages: [ChatPage]
    ) -> String? {
        var sections: [String] = []
        if let current {
            var header = ["Playhouse chat page metadata, not part of the user's message. This standalone chat is split into titled pages, and each page is its own conversation. This session has not loaded any page's turns."]
            header.append("Current page: \(chatPageLabel(current.page))")
            if let excerpt = latestExchange(of: current) {
                header.append("Its latest exchange, shortened:\n\(excerpt)")
            }
            if !recentPages.isEmpty {
                header.append("Recent pages, newest first:\n" + recentPages.map { "- \(chatPageLabel($0))" }.joined(separator: "\n"))
            }
            if currentIsUserNewPage {
                header.append("The user started this new page for their message, so treat it as a new topic rather than a continuation of the previous page. Name the page in this turn's close-turn with --continues false --new-title \"<short title>\"; Playhouse gives this page that title instead of opening another one. You can still read an earlier page with chat page read <page-id> when the message asks about it.")
            } else {
                header.append("If the user's message continues the current page or a recent page and this excerpt is not enough, run chat page read <page-id> to load that page before answering. Otherwise do not load any page.")
            }
            sections.append(header.joined(separator: "\n\n"))
        }
        // Attached pages share one transcript budget, so several never outgrow a single page.
        let pageLimit = characterLimit / max(fullPages.count, 1)
        let full = fullPages.compactMap { page -> String? in
            transcript(messages: page.messages, limit: pageLimit).map { "Playhouse page \(chatPageLabel(page.page)):\n\n\($0)" }
        }
        if !full.isEmpty {
            let preamble = current == nil ? chatPagePreamble : "Pages the user attached to this turn, in full:"
            sections.append(([preamble] + full).joined(separator: "\n\n"))
        }
        guard !sections.isEmpty else { return nil }
        return """
        \(openTag)
        \(sections.joined(separator: "\n\n"))
        \(closeTag)
        """
    }

    private static func chatPageLabel(_ page: StandaloneChatPage) -> String {
        let count = page.messageCount == 1 ? "1 message" : "\(page.messageCount) messages"
        return "\"\(page.title)\" (id: \(page.id), \(count))"
    }

    /// The page's last user message and the last reply after it, each cut to the excerpt limit.
    private static func latestExchange(of page: ChatPage) -> String? {
        let visible = page.messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let questionIndex = visible.lastIndex(where: { $0.role == .user }) else { return nil }
        let exchange = [visible[questionIndex]] + (visible[(questionIndex + 1)...].last(where: { $0.role == .assistant }).map { [$0] } ?? [])
        return exchange.map { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortened = text.count > chatPageExcerptCharacterLimit
                ? String(text.prefix(chatPageExcerptCharacterLimit)) + " […]"
                : text
            let speaker = message.role == .user ? "User" : (message.provider ?? .codex).displayName
            return "\(speaker): \(shortened)"
        }.joined(separator: "\n\n")
    }

    /// The visible turns as `Speaker: text` lines, newest kept when they exceed the limit.
    package static func transcript(messages: [ConversationMessage], limit: Int = characterLimit) -> String? {
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
        if transcript.count > limit {
            transcript = "[Earlier turns omitted]\n\n" + String(transcript.suffix(limit))
        }
        return transcript
    }

    package static func prompt(_ text: String, context: String?) -> String {
        guard let context else { return text }
        return text.isEmpty ? context : "\(context)\n\n\(text)"
    }

    /// Removes a handoff block that a native transcript stored with the prompt.
    package static func stripContext(from text: String) -> String {
        guard text.hasPrefix(openTag), let close = text.range(of: closeTag) else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

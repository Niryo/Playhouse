// DEBUG-IMPORT: Temporary debugging aid. Delete this whole folder together with
// every line marked `// DEBUG-IMPORT:` (see the removal note at the bottom).

import AppKit
import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Imports a conversation that Claude Code or Codex recorded in another client
/// (VS Code, a terminal) into a new Playhouse task, so the same conversation can
/// be compared side by side.
///
/// Nothing here renders or stores rows of its own:
/// - Codex: Playhouse already shows a Codex task by loading its native thread
///   through the Codex app-server (`thread/resume`). The import links the new
///   task to the rollout's thread ID, and the existing history path does the rest.
/// - Claude: the session file is replayed through `ClaudeSessionRunner`'s live
///   stream-json handler, with its callbacks wired to the same transcript
///   recording `ConversationManager` uses for a live turn. Only where the on-disk
///   format differs from the live stream is a line adapted (see
///   `ClaudeSessionFileAdapter`); lines with no live equivalent are skipped.
///
/// Both imports link the task to the original session, so a follow-up message
/// resumes it.
struct DebugConversationImportMenu: View {
    let modelContainer: ModelContainer

    var body: some View {
        Button("Import Conversation…") {
            Task { @MainActor in await DebugConversationImporter.pickAndImport(container: modelContainer) }
        }
        .buttonHoverPointer()
        .help("Import a Claude Code or Codex conversation into a new task")
    }
}

@MainActor
enum DebugConversationImporter {
    nonisolated static let log = Logger(subsystem: "Playhouse", category: "DebugConversationImport")

    struct ImportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func pickAndImport(container: ModelContainer) async {
        let panel = NSOpenPanel()
        panel.title = "Import a Claude Code or Codex conversation"
        panel.message = "Pick a Claude session (~/.claude/projects/…/<session>.jsonl) or a Codex rollout (~/.codex/sessions/…/*.jsonl)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try await importConversation(at: url, container: container)
            alert("Conversation imported", summary)
        } catch {
            alert("Couldn't import the conversation", error.localizedDescription)
        }
    }

    static func importConversation(at url: URL, container: ModelContainer) async throws -> String {
        let startedAt = Date()
        // Reading and decoding a large session (tens of MB) stays off the main thread.
        let parsed = try await Task.detached(priority: .userInitiated) { try SessionFile.parse(url) }.value
        let tasks = BoardTaskManager(modelContext: container.mainContext)
        let summary: String
        switch parsed {
        case .codex(let threadID, let cwd):
            let task = try await tasks.create(title: "Imported: \(threadID)", workspaceRoots: [workspaceRoot(cwd)], provider: .codex)
            _ = try await tasks.persistConversationID(task.id, provider: .codex, id: threadID)
            _ = try await tasks.setLifecycleStatus(task.id, to: .waitingResponse)
            summary = "Codex thread \(threadID) is linked to a new task. Playhouse loads it through the Codex app-server when you open the task."
        case .claude(let sessionID, let cwd, let steps):
            let task = try await tasks.create(title: "Importing: \(sessionID)", workspaceRoots: [workspaceRoot(cwd)], provider: .claude)
            _ = try await tasks.persistConversationID(task.id, provider: .claude, id: sessionID)
            let stats = try await ClaudeReplay(taskID: task.id, tasks: tasks).run(steps)
            _ = try await tasks.rename(task.id, title: "Imported: \(sessionID)")
            _ = try await tasks.setLifecycleStatus(task.id, to: .waitingResponse)
            summary = "Claude session \(sessionID): \(stats.turns) turns, \(stats.replayed) replayed events, \(stats.skipped) skipped lines."
        }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
        log.debug("Imported \(url.path, privacy: .public) in \(elapsed, privacy: .public)")
        return "\(summary) (\(elapsed))"
    }

    private static func workspaceRoot(_ cwd: String?) -> String {
        if let cwd, WorkspaceSettings.validDirectoryURL(for: cwd) != nil { return cwd }
        return NSHomeDirectory()
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Session files

/// Raw JSON objects decoded off the main thread and handed to it as-is.
struct DebugImportSteps: @unchecked Sendable {
    let items: [ClaudeSessionFileAdapter.Step]
    let skippedLineCount: Int
}

enum SessionFile: Sendable {
    case codex(threadID: String, cwd: String?)
    case claude(sessionID: String, cwd: String?, steps: DebugImportSteps)

    nonisolated static func parse(_ url: URL) throws -> SessionFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var objects: [[String: Any]] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                DebugConversationImporter.log.debug("Skipping an unreadable line")
                continue
            }
            objects.append(object)
        }
        if let meta = objects.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
           let threadID = (meta["id"] as? String) ?? (meta["session_id"] as? String) {
            return .codex(threadID: threadID, cwd: meta["cwd"] as? String)
        }
        let conversational = objects.filter { ["user", "assistant"].contains($0["type"] as? String ?? "") }
        guard let sessionID = conversational.lazy.compactMap({ $0["sessionId"] as? String }).first
                ?? (url.pathExtension == "jsonl" ? url.deletingPathExtension().lastPathComponent : nil),
              !conversational.isEmpty else {
            throw DebugConversationImporter.ImportError("This file isn't a Claude Code session or a Codex rollout.")
        }
        let cwd = conversational.lazy.compactMap { $0["cwd"] as? String }.first
        return .claude(sessionID: sessionID, cwd: cwd, steps: ClaudeSessionFileAdapter.steps(from: objects))
    }
}

// MARK: - Claude on-disk → live stream-json

/// Turns a Claude Code session file into the messages its live
/// `--output-format stream-json` stream would have carried.
///
/// The session file stores the same `assistant` (one line per content block,
/// sharing the call's message ID) and `user`/`tool_result` lines the live
/// stream sends. It differs in what the CLI writes only to the stream:
/// - `stream_event message_start` before each parent model call, which the
///   runner uses to know a woken parent has consumed a notification;
/// - `system task_started` / `task_notification` for background shells and
///   agents, which the file instead records in `toolUseResult` and as a
///   `<task-notification>` user prompt;
/// - `result` at the end of each turn, which the file never records.
/// Human prompts mark turn boundaries, as each would be its own Playhouse send.
enum ClaudeSessionFileAdapter {
    enum Step {
        /// A human prompt: a new Playhouse turn, or a steer when background
        /// work keeps the previous one open (as Playhouse would have treated it).
        case prompt(text: String, imageDataURLs: [String], createdAt: Date?, modelID: String?, isSteer: Bool)
        case message([String: Any])
        /// The synthesized `result` that settles the current turn.
        case endTurn
    }

    nonisolated static func steps(from objects: [[String: Any]]) -> DebugImportSteps {
        var steps: [Step] = []
        var turnOpen = false
        var lastParentMessageID: String?
        var toolNames: [String: String] = [:]
        var startedTaskIDs = Set<String>()
        var outstandingTasks: [String: String] = [:]  // task ID → tool use ID
        var awaitingParentWake = false
        var skipped: [String: Int] = [:]
        // Background work the file later reports finished. Work it never
        // reports (a shell the user killed, a session closed early) must not
        // hold every later prompt inside one turn.
        let notifiedTaskIDs = Set(objects.compactMap { object -> String? in
            guard object["type"] as? String == "user", let body = object["message"] as? [String: Any] else { return nil }
            let text = (body["content"] as? String)
                ?? (body["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return taskNotification(text)?.taskID
        })
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func messageStart() {
            steps.append(.message(["type": "stream_event", "event": ["type": "message_start"]]))
            awaitingParentWake = false
        }
        func endTurn() {
            guard turnOpen else { return }
            if awaitingParentWake { messageStart() }
            steps.append(.endTurn)
            turnOpen = false
        }
        func skip(_ kind: String) { skipped[kind, default: 0] += 1 }

        for object in objects {
            let type = object["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else {
                skip(type == "system" ? "system:\(object["subtype"] as? String ?? "")" : type)
                continue
            }
            // Subagent lines reach the live stream tagged with their parent
            // tool, where the runner only updates the agent row's detail.
            if object["isSidechain"] as? Bool == true { skip("sidechain"); continue }
            guard let body = object["message"] as? [String: Any] else { skip("\(type):no-message"); continue }

            if type == "assistant" {
                guard turnOpen else { skip("assistant:outside-turn"); continue }
                let id = body["id"] as? String
                if id == nil || id != lastParentMessageID { messageStart() }
                lastParentMessageID = id
                for block in body["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    if let id = block["id"] as? String { toolNames[id] = block["name"] as? String }
                }
                steps.append(.message(object))
                continue
            }

            if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true {
                skip("user:meta")
                continue
            }
            let content = body["content"]
            let blocks = content as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                guard turnOpen else { skip("tool_result:outside-turn"); continue }
                steps.append(.message(object))
                // The CLI tells the live stream a backgrounded call started
                // running; the file keeps the task ID on the tool result.
                if let result = object["toolUseResult"] as? [String: Any],
                   let toolUseID = blocks.first(where: { $0["type"] as? String == "tool_result" })?["tool_use_id"] as? String {
                    let taskID = (result["backgroundTaskId"] as? String)
                        ?? (result["isAsync"] as? Bool == true ? result["agentId"] as? String : nil)
                    if let taskID, notifiedTaskIDs.contains(taskID) {
                        let taskType = toolNames[toolUseID] == "Bash" ? "local_bash" : "local_agent"
                        steps.append(.message([
                            "type": "system", "subtype": "task_started", "task_id": taskID,
                            "tool_use_id": toolUseID, "task_type": taskType,
                        ]))
                        startedTaskIDs.insert(taskID)
                        outstandingTasks[taskID] = toolUseID
                    }
                }
                continue
            }

            let text = (content as? String)
                ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            if let notification = taskNotification(text) {
                guard turnOpen else { skip("task-notification:outside-turn"); continue }
                if !startedTaskIDs.contains(notification.taskID) {
                    skip("task-notification:unknown-task")
                }
                steps.append(.message([
                    "type": "system", "subtype": "task_notification", "task_id": notification.taskID,
                    "tool_use_id": notification.toolUseID ?? outstandingTasks[notification.taskID] ?? "",
                    "status": notification.status, "summary": notification.summary as Any,
                ]))
                outstandingTasks.removeValue(forKey: notification.taskID)
                awaitingParentWake = true
                continue
            }
            let images = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "image", let source = block["source"] as? [String: Any],
                      source["type"] as? String == "base64",
                      let media = source["media_type"] as? String, let data = source["data"] as? String else { return nil }
                return "data:\(media);base64,\(data)"
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
                skip("user:empty")
                continue
            }
            let createdAt = (object["timestamp"] as? String).flatMap(timestamps.date(from:))
            // Live, a prompt sent while background work keeps the turn running
            // is steered into that turn rather than starting a new one.
            let isSteer = turnOpen && !outstandingTasks.isEmpty
            if !isSteer {
                endTurn()
                turnOpen = true
            }
            steps.append(.prompt(text: text, imageDataURLs: images, createdAt: createdAt, modelID: nil, isSteer: isSteer))
        }
        // The session ended; background work still listed as running is not
        // running any more, and the live turn would have been settled.
        if turnOpen {
            for (taskID, toolUseID) in outstandingTasks {
                steps.append(.message([
                    "type": "system", "subtype": "task_notification", "task_id": taskID,
                    "tool_use_id": toolUseID, "status": "stopped",
                ]))
                awaitingParentWake = true
            }
        }
        endTurn()
        for (kind, count) in skipped.sorted(by: { $0.key < $1.key }) {
            DebugConversationImporter.log.debug("Skipped \(count) \(kind, privacy: .public) line(s) with no live stream equivalent")
        }
        return DebugImportSteps(items: attributingModels(steps), skippedLineCount: skipped.values.reduce(0, +))
    }

    /// The model each turn ran on, which the live path stamps on the prompt.
    nonisolated private static func attributingModels(_ steps: [Step]) -> [Step] {
        var result = steps
        var nextModel: String?
        for index in result.indices.reversed() {
            switch result[index] {
            case .message(let object):
                if let model = (object["message"] as? [String: Any])?["model"] as? String, model != "<synthetic>" {
                    nextModel = model
                }
            case .prompt(let text, let images, let createdAt, _, let isSteer):
                result[index] = .prompt(text: text, imageDataURLs: images, createdAt: createdAt, modelID: nextModel, isSteer: isSteer)
            case .endTurn:
                continue
            }
        }
        return result
    }

    private struct Notification {
        let taskID: String
        let toolUseID: String?
        let status: String
        let summary: String?
    }

    nonisolated private static func taskNotification(_ text: String) -> Notification? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<task-notification>") else { return nil }
        func tag(_ name: String) -> String? {
            guard let open = trimmed.range(of: "<\(name)>"),
                  let close = trimmed.range(of: "</\(name)>", range: open.upperBound..<trimmed.endIndex) else { return nil }
            return String(trimmed[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let taskID = tag("task-id") else { return nil }
        return Notification(taskID: taskID, toolUseID: tag("tool-use-id"), status: tag("status") ?? "completed", summary: tag("summary"))
    }
}

// MARK: - Claude replay

/// Feeds the adapted messages through the live Claude stream handler and
/// records its callbacks exactly as `ConversationManager.sendReserved` does
/// for a live turn.
@MainActor
private struct ClaudeReplay {
    struct Stats { var turns = 0; var replayed = 0; var skipped = 0 }

    let taskID: UUID
    let tasks: BoardTaskManager

    func run(_ parsed: DebugImportSteps) async throws -> Stats {
        let conversations = ConversationManager(
            tasks: tasks,
            clients: ConversationClients(codex: CodexAppServerClient(), claude: ClaudeCodeClient(), opencode: OpenCodeClient())
        )
        let store = try tasks.conversationTranscriptStore()
        guard let segmentID = try await conversations.debugImportPrepareSegmentID(taskID: taskID) else {
            throw DebugConversationImporter.ImportError("Playhouse couldn't open a Claude transcript segment for the task.")
        }
        // Never launched: only its stream handler is used.
        let runner = ClaudeSessionRunner(
            sessionID: UUID().uuidString.lowercased(), executable: "", configDirectoryOverride: nil,
            persistsSessions: false, owner: nil
        )
        var turnID = ""
        var modelID: String?
        var finalMessageCount = 0
        let taskID = taskID
        runner.finalMessageHandler = { answer in
            let split = LeakedTurnOutcome.split(answer)
            guard !split.text.isEmpty else { return }
            finalMessageCount += 1
            conversations.debugImportRecordClaudeMessage(taskID: taskID, turnID: turnID, modelID: modelID, ConversationMessage(
                id: "\(turnID)-final-\(finalMessageCount)", role: .assistant, text: split.text, phase: "final_answer"
            ))
        }
        runner.progressMessageHandler = { message in
            conversations.debugImportRecordClaudeMessage(taskID: taskID, turnID: turnID, modelID: modelID, message)
        }
        runner.activityHandler = { activity in
            // Replay runs in milliseconds, so the runner's wall-clock durations
            // would be meaningless; the file's real ones aren't in the stream.
            var activity = activity
            activity.durationMs = nil
            conversations.debugImportRecordClaudeActivity(taskID: taskID, turnID: turnID, activity)
        }

        var stats = Stats(skipped: parsed.skippedLineCount)
        for (index, step) in parsed.items.enumerated() {
            switch step {
            case .prompt(let text, let images, let createdAt, let promptModelID, let isSteer):
                modelID = promptModelID ?? modelID
                if isSteer {
                    conversations.debugImportRecordClaudeMessage(taskID: taskID, turnID: turnID, modelID: modelID, ConversationMessage(
                        id: UUID().uuidString.lowercased(), role: .user, text: text, imageDataURLs: images,
                        createdAt: createdAt ?? .now
                    ))
                    continue
                }
                turnID = UUID().uuidString.lowercased()
                finalMessageCount = 0
                stats.turns += 1
                let newTurnID = turnID
                try store.mutate(taskID, turns: .none) { transcript in
                    transcript.turns.append(.init(id: newTurnID, segmentID: segmentID, messages: [ConversationMessage(
                        id: "\(newTurnID)-user", role: .user, text: text, imageDataURLs: images,
                        turnID: newTurnID, provider: .claude, createdAt: createdAt ?? .now, modelID: modelID
                    )]))
                }
            case .message(let message):
                stats.replayed += 1
                await runner.debugImportReplay(message)
            case .endTurn:
                await runner.debugImportReplay(["type": "result", "subtype": "success", "is_error": false, "result": ""])
            }
            // Let the UI breathe during a long replay.
            if index % 50 == 0 { await Task.yield() }
        }
        return stats
    }
}

// MARK: - How to remove
//
// 1. Delete the folder `Playhouse/App/DebugConversationImport/`.
// 2. Delete every line containing `DEBUG-IMPORT:`:
//      grep -rn "DEBUG-IMPORT:" Playhouse
//    - Playhouse/App/PlayhouseApp.swift — the `CommandMenu("Debug")` line.
//    - Playhouse/App/ClaudeCodeClient.swift — `debugImportReplay(_:)` on ClaudeSessionRunner.
//    - Playhouse/App/BridgeCore.swift — the three `debugImport…` forwards on ConversationManager.
// 3. Delete the lines naming `DebugConversationImport.swift` in
//    Playhouse.xcodeproj/project.pbxproj (build file, file reference, App group
//    child, Sources phase entry):
//      grep -n "DebugConversationImport" Playhouse.xcodeproj/project.pbxproj

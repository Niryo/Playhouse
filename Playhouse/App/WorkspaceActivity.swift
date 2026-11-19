import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

struct ConversationActivity: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var detail: String
    let status: String
    var childThreadID: String? = nil
    var agentPath: String? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil
    var toolKind: String? = nil
    var server: String? = nil
    var tool: String? = nil
    var durationMs: Int? = nil
    var startedAt: Date? = nil
    var isContextCompaction: Bool = false
    var turnID: String? = nil
    var timelineOrder: Int? = nil
    /// The provider's own background-task identifier for a backgrounded Claude
    /// Agent/Task call. Durable across process restarts, so a bare task
    /// notification with no matching in-memory tool-use id can still be
    /// resolved against the persisted activity that originally started it.
    var backgroundTaskID: String? = nil
    /// The explicit result summary from Claude's terminal task notification.
    /// Activity detail may contain progress text before that notification.
    var backgroundTaskSummary: String? = nil
    /// A one-line description of the call (a command's stated purpose, a file
    /// path), shown beside the tool's name in the conversation timeline.
    var summary: String? = nil
    /// What the tool was given and what it returned, as the timeline's IN and
    /// OUT blocks show them; nil when the call has no meaningful text for it.
    var input: String? = nil
    var output: String? = nil
    /// The message this call followed, which places the call in the
    /// conversation timeline; nil for calls recorded before Playhouse kept it.
    var afterMessageID: String? = nil
    /// What fired a context compaction and how far it shrank the context;
    /// nil for other activities and for compactions recorded without it.
    var compaction: ContextCompactionDetails? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, status, childThreadID, agentPath, model, reasoningEffort
        case toolKind, server, tool, durationMs, startedAt, isContextCompaction, turnID, timelineOrder
        case backgroundTaskID, backgroundTaskSummary, summary, input, output, afterMessageID, compaction
    }

    init(
        id: String,
        title: String,
        detail: String,
        status: String,
        childThreadID: String? = nil,
        agentPath: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        toolKind: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        durationMs: Int? = nil,
        startedAt: Date? = nil,
        isContextCompaction: Bool = false,
        turnID: String? = nil,
        timelineOrder: Int? = nil,
        backgroundTaskID: String? = nil,
        backgroundTaskSummary: String? = nil,
        summary: String? = nil,
        input: String? = nil,
        output: String? = nil,
        afterMessageID: String? = nil,
        compaction: ContextCompactionDetails? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.childThreadID = childThreadID
        self.agentPath = agentPath
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.toolKind = toolKind
        self.server = server
        self.tool = tool
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.isContextCompaction = isContextCompaction
        self.turnID = turnID
        self.timelineOrder = timelineOrder
        self.backgroundTaskID = backgroundTaskID
        self.backgroundTaskSummary = backgroundTaskSummary
        self.summary = summary
        self.input = input
        self.output = output
        self.afterMessageID = afterMessageID
        self.compaction = compaction
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decode(String.self, forKey: .detail)
        status = try values.decode(String.self, forKey: .status)
        childThreadID = try values.decodeIfPresent(String.self, forKey: .childThreadID)
        agentPath = try values.decodeIfPresent(String.self, forKey: .agentPath)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        toolKind = try values.decodeIfPresent(String.self, forKey: .toolKind)
        server = try values.decodeIfPresent(String.self, forKey: .server)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        isContextCompaction = try values.decodeIfPresent(Bool.self, forKey: .isContextCompaction) ?? false
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        timelineOrder = try values.decodeIfPresent(Int.self, forKey: .timelineOrder)
        backgroundTaskID = try values.decodeIfPresent(String.self, forKey: .backgroundTaskID)
        backgroundTaskSummary = try values.decodeIfPresent(String.self, forKey: .backgroundTaskSummary)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        input = try values.decodeIfPresent(String.self, forKey: .input)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        afterMessageID = try values.decodeIfPresent(String.self, forKey: .afterMessageID)
        compaction = try values.decodeIfPresent(ContextCompactionDetails.self, forKey: .compaction)
    }

    /// Whether the conversation timeline shows this call as a tool row of its
    /// own: agents and context compaction have dedicated rows instead, and
    /// Playhouse's own progress and outcome reports are bookkeeping, not work.
    var isTimelineToolCall: Bool {
        !isSubagent && !isContextCompaction
            && input.map { TaskProgressReportInstructions.reportCommand(in: $0) == nil } != false
    }

    /// The standalone chat page this call loads into the agent's context, when the call is the
    /// agent's `chat page read <page-id>` command. Both providers name a shell call "Running
    /// <command>", so this reads the same way for Claude and Codex, live and from history.
    var recalledChatPageID: String? {
        Self.recalledChatPageID(inCommand: input ?? title)
    }

    static func recalledChatPageID(inCommand command: String) -> String? {
        guard command.contains(TaskProgressReportInstructions.executableName),
              let match = command.firstMatch(of: #/\schat page read\s+['"]?([A-Za-z0-9-]+)/#) else { return nil }
        return String(match.1)
    }

    /// The longest command text the timeline's IN block keeps.
    static let timelineInputLimit = 4_000

    /// Timeline calls visible next to `visibleMessageIDs`: calls from excluded (private or
    /// sensitive) turns and calls whose message isn't shown are left out, so every history
    /// path hides the same ones.
    static func visibleTimelineActivities(
        _ activities: [ConversationActivity],
        visibleMessageIDs: Set<String>,
        excludedTurnIDs: Set<String>
    ) -> [ConversationActivity] {
        activities.filter { activity in
            activity.isTimelineToolCall
                && activity.turnID.map(excludedTurnIDs.contains) != true
                && activity.afterMessageID.map(visibleMessageIDs.contains) == true
        }
    }

    /// Carries what an update to this call doesn't restate (its timeline
    /// position, input, output, and measured duration) over from the version already recorded.
    func preservingTimelineFields(of existing: ConversationActivity) -> ConversationActivity {
        var merged = self
        merged.durationMs = durationMs ?? existing.durationMs
        merged.summary = summary ?? existing.summary
        merged.input = input ?? existing.input
        merged.output = output ?? existing.output
        merged.afterMessageID = afterMessageID ?? existing.afterMessageID
        merged.startedAt = startedAt ?? existing.startedAt
        merged.compaction = compaction ?? existing.compaction
        return merged
    }

    /// Records a compaction row into a list of rows. Only one compaction runs at a time, so the
    /// row also supersedes every compaction row still in progress under another id: it takes the
    /// first one's place and the rest are dropped. A compaction whose start was reported more than
    /// once, or whose finish arrived under a new id, is then one row that ends, instead of rows
    /// left spinning beside it.
    static func upsertCompaction(_ activity: ConversationActivity, into activities: inout [ConversationActivity]) {
        let staleIDs = Set(activities.filter {
            $0.isContextCompaction && $0.status == "inProgress" && $0.id != activity.id
        }.map(\.id))
        if let existing = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[existing] = activity.preservingTimelineFields(of: activities[existing])
        } else if let stale = activities.firstIndex(where: { staleIDs.contains($0.id) }) {
            var replacement = activity.preservingTimelineFields(of: activities[stale])
            replacement.timelineOrder = activity.timelineOrder ?? activities[stale].timelineOrder
            activities[stale] = replacement
        } else {
            activities.append(activity)
        }
        activities.removeAll { staleIDs.contains($0.id) }
    }

    var isSubagent: Bool { childThreadID != nil }

    var isActive: Bool { status.lowercased() == "inprogress" || status.lowercased() == "running" }

    /// How this call is named in a task's token breakdown: an MCP call by
    /// `server/tool`, a subagent by the agent it ran, anything else by its tool
    /// name. Falls back to the visible title so a call is never counted as "".
    var tokenUsageLabel: String {
        if toolKind == "mcp", let server {
            return tool.map { "\(server)/\($0)" } ?? server
        }
        if let agentPath, !agentPath.isEmpty { return "Agent: \(agentPath)" }
        if let tool, !tool.isEmpty { return tool }
        return title
    }

    /// The most characters of a title an activity row shows until the reader expands it.
    static let titlePreviewLimit = 160

    /// The title as a collapsed activity row shows it: its first line, cut to
    /// `titlePreviewLimit` characters and ending in an ellipsis. Nil when the whole title fits.
    /// A command's title carries the whole command, which can be tens of thousands of
    /// characters (a heredoc that writes a file); laying all of that out on every pass
    /// of the transcript stalls the main thread, so only the preview reaches a `Text`
    /// until the reader asks for the rest.
    /// Every row computes it on every update, so it reads at most one character past the limit.
    var titlePreview: String? {
        let head = title.prefix(Self.titlePreviewLimit + 1)
        // `isNewline`, since "\r\n" is one Character that equals neither "\n" nor "\r".
        let firstLine = head.prefix { !$0.isNewline }
        guard firstLine.count > Self.titlePreviewLimit || firstLine.endIndex != title.endIndex else { return nil }
        return firstLine.prefix(Self.titlePreviewLimit).trimmingCharacters(in: .whitespaces) + "…"
    }

    func durationLabel(at now: Date = .now) -> String? {
        if let durationMs {
            return "Duration · \(durationMs) ms"
        }
        guard isActive, let startedAt else { return nil }
        let elapsedMs = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
        return "Running · \(elapsedMs) ms"
    }

    var statusLabel: String {
        switch status.lowercased() {
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "stopped": "Stopped"
        case "inprogress", "running": "In progress"
        default: status
        }
    }

    var timelineStatus: String {
        switch status.lowercased() {
        case "inprogress", "running": "started working"
        case "completed": "finished working"
        case "interrupted": "was interrupted"
        case "stopped": "was stopped"
        case "failed": "failed"
        default: "working · \(statusLabel.lowercased())"
        }
    }

    static func from(item: [String: Any], lifecycle: String? = nil, turnID: String? = nil, timelineOrder: Int? = nil, startedAt: Date? = nil, measuredDurationMs: Int? = nil) -> ConversationActivity? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let itemStatus = item["status"] as? String
        // A completed item keeps the outcome it reports (failed, declined), which the
        // transcript stores as the item's final status.
        let status = lifecycle == "completed" && itemStatus.map({ !["inProgress", "completed"].contains($0) }) == true
            ? itemStatus! : lifecycle ?? itemStatus ?? "inProgress"
        switch type {
        case "contextCompaction":
            // The installed app-server schema currently supplies only id/type.
            // Never serialize unknown machine fields into user-visible prose.
            return ConversationActivity(
                id: id,
                title: "Context compacted",
                detail: "",
                status: status,
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt,
                isContextCompaction: true,
                turnID: turnID,
                timelineOrder: timelineOrder
            )
        case "subAgentActivity":
            guard let childThreadID = item["agentThreadId"] as? String else { return nil }
            let kind = item["kind"] as? String ?? "unknown"
            let status: String
            switch kind.lowercased() {
            case "started", "interacted": status = "inProgress"
            case "completed": status = "completed"
            case "interrupted": status = "interrupted"
            default: status = kind
            }
            let path = item["agentPath"] as? String ?? "Subagent"
            let pathName = path.split(separator: "/").last.map(String.init) ?? path
            let spacedName = pathName.replacingOccurrences(of: "_", with: " ")
            let name = spacedName.prefix(1).uppercased() + spacedName.dropFirst()
            let metadata = [item["model"] as? String, item["reasoningEffort"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return ConversationActivity(
                id: childThreadID,
                title: name.isEmpty ? "Subagent" : name,
                detail: [path, metadata].filter { !$0.isEmpty }.joined(separator: "\n"),
                status: status,
                childThreadID: childThreadID,
                agentPath: path,
                model: item["model"] as? String,
                reasoningEffort: item["reasoningEffort"] as? String,
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt
            )
        case "commandExecution":
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            let cwd = item["cwd"] as? String
            let output = item["aggregatedOutput"] as? String
            let detail = [cwd.map { "in \($0)" }, output.map { String($0.suffix(2_000)) }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return ConversationActivity(
                id: id,
                title: command.isEmpty ? "Running command" : "Running \(command)",
                detail: detail,
                status: status,
                // Named to match Claude's equivalent built-in tool, so the token
                // usage breakdown groups the same kind of work the same way
                // regardless of which provider ran it.
                tool: "Bash",
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt,
                turnID: turnID,
                summary: cwd.map { "in \($0)" },
                input: command.isEmpty ? nil : String(command.prefix(ConversationActivity.timelineInputLimit)),
                output: output.flatMap { $0.isEmpty ? nil : String($0.suffix(2_000)) }
            )
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            return ConversationActivity(
                id: id,
                title: paths.isEmpty ? "Editing files" : "Editing \(paths.count) \(paths.count == 1 ? "file" : "files")",
                detail: paths.joined(separator: ", "),
                status: status,
                tool: "Edit",
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt
            )
        case "webSearch":
            return ConversationActivity(id: id, title: "Searching the web", detail: item["query"] as? String ?? "", status: status, tool: "WebSearch", durationMs: item["durationMs"] as? Int ?? measuredDurationMs, startedAt: startedAt)
        case "imageView":
            return ConversationActivity(id: id, title: "Viewing image", detail: item["path"] as? String ?? "", status: status, tool: "ViewImage", durationMs: item["durationMs"] as? Int ?? measuredDurationMs, startedAt: startedAt)
        case "mcpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let error = item["error"] as? [String: Any]
            let summary: String
            if status == "failed" || error != nil {
                summary = "Tool call failed"
            } else if status == "completed" {
                let result = item["result"] as? [String: Any]
                let count = (result?["content"] as? [Any])?.count ?? 0
                summary = count > 0 ? "Returned \(count) result \(count == 1 ? "item" : "items")" : "Completed without result details"
            } else {
                summary = "Waiting for result"
            }
            return ConversationActivity(
                id: id,
                title: "MCP · \(tool ?? "Tool")",
                detail: [server.map { "Server · \($0)" }, summary].compactMap { $0 }.joined(separator: "\n"),
                status: error == nil ? status : "failed",
                toolKind: "mcp",
                server: server,
                tool: tool,
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt
            )
        case "dynamicToolCall":
            let tool = item["tool"] as? String
            let success = item["success"] as? Bool
            let summary: String
            if status == "failed" || success == false {
                summary = "Tool call failed"
            } else if status == "completed" {
                let count = (item["contentItems"] as? [Any])?.count ?? 0
                summary = count > 0 ? "Returned \(count) result \(count == 1 ? "item" : "items")" : "Tool call completed without result details"
            } else {
                summary = "Waiting for result"
            }
            return ConversationActivity(
                id: id,
                title: "Tool · \(tool ?? "Dynamic tool")",
                detail: summary,
                status: success == false ? "failed" : status,
                toolKind: "dynamic",
                tool: tool,
                durationMs: item["durationMs"] as? Int ?? measuredDurationMs,
                startedAt: startedAt
            )
        case "collabAgentToolCall":
            guard item["tool"] as? String == "spawnAgent" else { return nil }
            let prompt = item["prompt"] as? String ?? ""
            let agentStates = item["agentsStates"] as? [String: [String: Any]] ?? [:]
            let stateDetails = agentStates.values.compactMap { state -> String? in
                guard let agentStatus = state["status"] as? String else { return nil }
                let message = state["message"] as? String
                return [agentStatus, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            }
            let detail = ([prompt] + stateDetails).filter { !$0.isEmpty }.joined(separator: "\n")
            return ConversationActivity(id: id, title: "Task delegated to subagent", detail: detail, status: status, tool: "Agent", durationMs: item["durationMs"] as? Int ?? measuredDurationMs, startedAt: startedAt)
        default:
            return nil
        }
    }
}

struct ConversationTurnDiff: Codable, Equatable {
    let unifiedDiff: String

    private struct FileChunk {
        let path: String
        let text: String
    }

    var changedFiles: [String] {
        var paths: [String] = []
        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("+++ b/") else { continue }
            let path = String(line.dropFirst(6))
            if path != "/dev/null", !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    func merging(_ update: ConversationTurnDiff) -> ConversationTurnDiff {
        var chunks = fileChunks()
        for updateChunk in update.fileChunks() {
            if let index = chunks.firstIndex(where: { $0.path == updateChunk.path }) {
                chunks[index] = updateChunk
            } else {
                chunks.append(updateChunk)
            }
        }
        guard !chunks.isEmpty else { return ConversationTurnDiff(unifiedDiff: update.unifiedDiff) }
        return ConversationTurnDiff(unifiedDiff: chunks.map(\.text).joined(separator: "\n"))
    }

    private func fileChunks() -> [FileChunk] {
        let lines = unifiedDiff.components(separatedBy: "\n")
        var chunks: [FileChunk] = []
        var chunkStart = 0
        var currentPath: String?

        func appendCurrentChunk(endingAt end: Int) {
            guard let path = currentPath else {
                chunkStart = end
                return
            }
            let text = lines[chunkStart..<end].joined(separator: "\n")
            chunks.append(FileChunk(path: path, text: text))
            chunkStart = end
            currentPath = nil
        }

        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("diff --git "), index > chunkStart {
                appendCurrentChunk(endingAt: index)
            } else if line.hasPrefix("--- a/"), currentPath != nil {
                appendCurrentChunk(endingAt: index)
            }

            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/"), currentPath == nil {
                currentPath = String(line.dropFirst(6))
            }
        }
        appendCurrentChunk(endingAt: lines.count)
        return chunks
    }

    static func fromFileChangeItems(_ items: [[String: Any]]) -> ConversationTurnDiff? {
        var chunks: [String] = []
        for item in items where item["type"] as? String == "fileChange" {
            let changes = item["changes"] as? [[String: Any]] ?? []
            for change in changes {
                guard let path = change["path"] as? String,
                      let diff = change["diff"] as? String, !diff.isEmpty else { continue }
                chunks.append("--- a/\(path)\n+++ b/\(path)\n\(diff)")
            }
        }
        guard !chunks.isEmpty else { return nil }
        return ConversationTurnDiff(unifiedDiff: chunks.joined(separator: "\n"))
    }
}

/// The images of one transcript message, read apart from its history page.
struct ConversationMessageImages: Codable, Equatable {
    let id: String
    /// The turn holding the message; message IDs are unique only within a turn.
    let turnID: String?
    let imageDataURLs: [String]
}

struct ConversationHistory: Codable, Equatable {
    var messages: [ConversationMessage]
    var activities: [ConversationActivity]
    /// Tool calls from every returned turn, each placed after the message it
    /// followed (`afterMessageID`), so earlier turns show their work too.
    var timelineActivities: [ConversationActivity] = []
    let diff: ConversationTurnDiff?
    var answeredAsyncQuestionIDs: [String] = []
    var pendingUserInputRequest: ConversationUserInputRequest?
    /// Dividers where the task's conversation moved to another provider.
    var providerBoundaries: [ConversationProviderBoundary] = []
    /// For a page of history, how many messages precede `messages`; nil when
    /// `messages` is the whole conversation.
    var earlierMessageCount: Int?
    /// For a page of history, how many messages follow `messages`; nil when
    /// `messages` is the whole conversation.
    var laterMessageCount: Int?
}

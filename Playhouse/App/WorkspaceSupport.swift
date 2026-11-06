import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

/// Shows `cursor` while the pointer is over the view, keeping the cursor stack balanced:
/// repeated hover events are ignored, and a view that disappears under the pointer pops it.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                guard isInside != isHovering else { return }
                isHovering = isInside
                if isInside {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

extension View {
    func buttonHoverPointer() -> some View {
        hoverCursor(.pointingHand)
    }

    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}

private struct ActionButtonHoverEmphasis: ViewModifier {
    @State private var isHovering = false
    var padding: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                Capsule()
                    .fill(Color.accentColor.opacity(isHovering ? 0.14 : 0))
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A native AppKit tooltip for `text`, carried by a click-through view behind the content.
/// SwiftUI's `.help` alone never presented a tooltip for most of the main window's controls (the
/// board header and the Done panel among them); an `NSView` with its own `toolTip` does.
private struct NativeToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.toolTip != text { nsView.toolTip = text }
    }

    private final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

extension View {
    /// `.help` that reliably shows a native tooltip on macOS; keeps `.help` for accessibility.
    func nativeHelp(_ text: String) -> some View {
        // Hidden from accessibility so the extra view cannot become, or resize, the control's element.
        help(text).background(NativeToolTip(text: text).accessibilityHidden(true))
    }
}

extension View {
    func actionButtonHoverEmphasis(padding: CGFloat = 4) -> some View {
        modifier(ActionButtonHoverEmphasis(padding: padding))
    }
}

enum WorkspaceSettings {
    static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"
    static let lastSelectedRepositoriesKey = "lastSelectedRepositories"
    static let recentRepositoriesKey = "recentRepositories"
    /// How many recently selected repositories are remembered and offered by the repository picker.
    static let recentRepositoryHistoryLimit = 20
    static let appearanceKey = "appearance"
    /// Whether the task view's sidebar is hidden to a narrow rail; one value shared by every task.
    static let taskSidebarCollapsedKey = "taskSidebarCollapsed"
    /// Whether the Changes section inside the task sidebar is collapsed; one value shared by every task.
    static let workspaceChangesSectionCollapsedKey = "workspaceChangesSectionCollapsed"
    static let defaultConversationProviderKey = "defaultConversationProvider"
    static let autoCreatePullRequestDefaultKey = "autoCreatePullRequestDefault"
    static let pullRequestModeDefaultKey = "pullRequestModeDefault"
    static let tokenUsageColorMaxKey = "tokenUsageColorMax"
    static let defaultTokenUsageColorMax = TokenUsageHeatmap.defaultColorMax
    static let cpuUsageColorMaxKey = "cpuUsageColorMax"
    static let defaultCPUUsageColorMax = CPUUsageHeatmap.defaultColorMax

    static var preferencesStore: UserDefaults {
        #if DEBUG
        if let suiteName = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    static func validDirectoryURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

enum WorkspaceTheme {
    static let windowBackground = adaptive(dark: (0x1E, 0x1E, 0x1E), light: .windowBackgroundColor)
    static let panelBackground = adaptive(dark: (0x25, 0x25, 0x26), light: .controlBackgroundColor)
    static let inputBackground = adaptive(dark: (0x3C, 0x3C, 0x3C), light: .textBackgroundColor)
    static let conversationText = adaptive(dark: (0xC5, 0xC5, 0xC5), light: .labelColor)
    static let accent = Color(nsColor: NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 204.0 / 255.0, alpha: 1))

    private static func adaptive(dark: (UInt8, UInt8, UInt8), light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(
                srgbRed: CGFloat(dark.0) / 255,
                green: CGFloat(dark.1) / 255,
                blue: CGFloat(dark.2) / 255,
                alpha: 1
            )
        })
    }
}

struct ConversationWorkspaceContext {
    let roots: [URL]
    let cwd: URL
    /// The skill folders each provider needs passed so it sees the whole
    /// gallery. Only a turn's own launch sets it.
    var skillBridge: SkillBridgeLaunch?

    init(roots: [URL]) throws {
        let normalized = roots.map(\.standardizedFileURL)
        guard normalized.allSatisfy({ WorkspaceSettings.validDirectoryURL(for: $0.path) != nil }) else {
            throw WorkspaceError.unavailableRoot
        }
        let uniqueRoots = Array(NSOrderedSet(array: normalized.map(\.path))).compactMap {
            ($0 as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        self.roots = uniqueRoots
        if let firstRoot = uniqueRoots.first {
            cwd = firstRoot
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
    }
}

enum WorkspaceError: LocalizedError {
    case unavailableRoot

    var errorDescription: String? {
        switch self {
        case .unavailableRoot:
            "One or more working folders are unavailable. Edit the task folders and try again."
        }
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, status, childThreadID, agentPath, model, reasoningEffort
        case toolKind, server, tool, durationMs, startedAt, isContextCompaction, turnID, timelineOrder
        case backgroundTaskID, backgroundTaskSummary, summary, input, output, afterMessageID
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
        afterMessageID: String? = nil
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
    }

    /// Whether the conversation timeline shows this call as a tool row of its
    /// own: agents and context compaction have dedicated rows instead, and
    /// Playhouse's own progress and outcome reports are bookkeeping, not work.
    var isTimelineToolCall: Bool {
        !isSubagent && !isContextCompaction
            && input.map { TaskProgressReportInstructions.reportCommand(in: $0) == nil } != false
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
    /// position, input, and output) over from the version already recorded.
    func preservingTimelineFields(of existing: ConversationActivity) -> ConversationActivity {
        var merged = self
        merged.summary = summary ?? existing.summary
        merged.input = input ?? existing.input
        merged.output = output ?? existing.output
        merged.afterMessageID = afterMessageID ?? existing.afterMessageID
        merged.startedAt = startedAt ?? existing.startedAt
        return merged
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
        let status = lifecycle ?? (item["status"] as? String ?? "inProgress")
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

struct ConversationHistory: Codable, Equatable {
    var messages: [ConversationMessage]
    let activities: [ConversationActivity]
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
}

enum RepositoryScanner {
    static func scan(parent: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            scanSynchronously(parent: parent)
        }.value
    }

    static func scanSynchronously(parent: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = manager.enumerator(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
              ) else { return [] }

        let markerAtParent = parent.appendingPathComponent(".git", isDirectory: false)
        if manager.fileExists(atPath: markerAtParent.path) {
            return [parent.standardizedFileURL]
        }

        var repositories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }

            let marker = url.appendingPathComponent(".git", isDirectory: false)
            if manager.fileExists(atPath: marker.path) {
                repositories.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return repositories.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

/// The environment work should run with. The bridge daemon scopes each request
/// to its caller's environment (`BridgeRequest.environment`) for the life of
/// that request's task, including across suspension points while other requests
/// interleave on the main actor. Outside a request, such as in the GUI app, this
/// is simply this process's own environment.
enum PlayhouseProcessEnvironment {
    @TaskLocal static var requestEnvironment: [String: String]?

    static var current: [String: String] {
        requestEnvironment ?? ProcessInfo.processInfo.environment
    }
}

/// One bridge request's diagnostics routing. A single daemon process serves
/// requests for different stores, so each request keeps its own store-directory
/// selection (as each XPC service process once had), and records it makes
/// before choosing that directory wait for it instead of landing elsewhere.
/// Only touched on the main actor.
final class PlayhouseDiagnosticsScope: @unchecked Sendable {
    let id = UUID()
    var directoryOverride: URL?
    var awaitingDirectory = true
}

/// What a request's background work needs to keep behaving as part of that
/// request after the request has returned: its environment and its diagnostics
/// scope. `Task.detached` doesn't inherit task-local values.
struct PlayhouseRequestContext: Sendable {
    @TaskLocal static var diagnosticsScope: PlayhouseDiagnosticsScope?

    let environment: [String: String]?
    let scope: PlayhouseDiagnosticsScope?

    @MainActor static func capture() -> PlayhouseRequestContext {
        PlayhouseRequestContext(environment: PlayhouseProcessEnvironment.requestEnvironment, scope: diagnosticsScope)
    }

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await PlayhouseProcessEnvironment.$requestEnvironment.withValue(environment) {
            try await Self.$diagnosticsScope.withValue(scope) {
                try await operation()
            }
        }
    }
}

enum PlayhouseAppIdentity {
    static var applicationIdentifier: String {
        Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
            ?? Bundle.main.bundleIdentifier ?? ""
    }

    static var isTestBundle: Bool {
        BridgeContract.isTestBundle(applicationIdentifier)
    }

    static var worktreeKey: String? {
        let prefix = "com.playhouse.app.worktree."
        guard applicationIdentifier.hasPrefix(prefix) else { return nil }
        let remainder = String(applicationIdentifier.dropFirst(prefix.count))
        let key = String(remainder.prefix(17))
        guard key.count == 17, key.first == "w",
              key.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let suffix = remainder.dropFirst(key.count)
        guard suffix.isEmpty || (isTestBundle && suffix.hasPrefix(".e2e.")) else { return nil }
        return key
    }

    static func defaultDataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Playhouse", isDirectory: true)
        guard let worktreeKey else { return support }
        return support.appendingPathComponent("Worktrees", isDirectory: true)
            .appendingPathComponent(worktreeKey, isDirectory: true)
    }
}

enum PlayhouseWorktreeManager {
    /// Task worktrees live in the app's data directory, so removing that one
    /// folder removes them too. Worktrees made before this stay at the paths
    /// their tasks recorded.
    static func defaultRoot(dataDirectory: String? = nil) -> URL {
        #if DEBUG
        if let override = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_WORKTREE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        // The same data directory the store opens: a window reads it from its
        // launch environment, the daemon from each request.
        let base = (dataDirectory ?? PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (try? PlayhouseAppIdentity.defaultDataDirectory())
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".playhouse", isDirectory: true)
        // Not "Worktrees": that folder already holds each worktree build's data
        // directory, and the file system ignores case.
        return base.appendingPathComponent("task-worktrees", isDirectory: true).standardizedFileURL
    }

    static func branchSlug(_ title: String) -> String {
        let lower = title.lowercased()
        var result = ""
        var needsSeparator = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        return result.isEmpty ? "task" : result
    }

    static func branchTitle(_ branch: String) -> String {
        branch
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func repositoryRoot(_ path: String) throws -> String {
        let result = try git(path, ["rev-parse", "--show-toplevel"]).output
        return URL(fileURLWithPath: result.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            .standardizedFileURL.path
    }

    static func defaultBranchFrom(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        return try defaultBranches(repository: repository).branchFrom
    }

    static func defaultLocalBranch(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        let current = try defaultBranches(repository: repository).mergeTarget
        guard !current.isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Choose a local branch as the merge target for \(repository).")
        }
        return current
    }

    static func resolve(spec: RepositoryWorktreeSpec, title: String, root: URL) throws -> RepositoryWorktreeRecord {
        let repository = try repositoryRoot(spec.repositoryPath)
        let branch = (spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? spec.branch!.trimmingCharacters(in: .whitespacesAndNewlines)
            : branchSlug(title)
        guard !branch.hasPrefix("-") else {
            throw BridgeCommandError(code: "invalid_argument", message: "Branch names can't begin with a hyphen.")
        }
        let branchCheck = try git(repository, ["check-ref-format", "--branch", branch], allowFailure: true)
        guard branchCheck.status == 0 else {
            throw BridgeCommandError(code: "invalid_argument", message: "'\(branch)' isn't a valid Git branch name.")
        }
        let defaults = try defaultBranchOptionsIfNeeded(repository: repository, spec: spec)
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom, defaults: defaults)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget, defaults: defaults)
        guard branch != mergeTarget else {
            throw BridgeCommandError(code: "invalid_argument", message: "A task branch can't also be its merge target: \(branch).")
        }
        let existing = try worktrees(repository: repository)
        if let path = existing.first(where: { $0.branch == branch })?.path {
            return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: path, branchFrom: branchFrom, createdByPlayhouse: false, mergeTarget: mergeTarget)
        }
        let branchExists = try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], allowFailure: true).status == 0
        let destination = managedPath(root: root, repository: repository, branch: branch)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BridgeCommandError(code: "operation_failed", message: "The worktree destination already exists: \(destination.path)")
        }
        if branchExists {
            _ = try git(repository, ["worktree", "add", destination.path, branch])
        } else {
            // A remote branch-from must not become the task branch's upstream.
            _ = try git(repository, ["worktree", "add", "--no-track", "-b", branch, destination.path, branchFrom])
        }
        return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: destination.path, branchFrom: branchFrom, createdByPlayhouse: true, mergeTarget: mergeTarget)
    }

    static func pendingRecord(spec: RepositoryWorktreeSpec) throws -> RepositoryWorktreeRecord {
        let repository = try repositoryRoot(spec.repositoryPath)
        let defaults = try defaultBranchOptionsIfNeeded(repository: repository, spec: spec)
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom, defaults: defaults)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget, defaults: defaults)
        let branch = spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            guard !branch.hasPrefix("-"), try git(repository, ["check-ref-format", "--branch", branch], allowFailure: true).status == 0 else {
                throw BridgeCommandError(code: "invalid_argument", message: "'\(branch)' isn't a valid Git branch name.")
            }
            guard branch != mergeTarget else {
                throw BridgeCommandError(code: "invalid_argument", message: "A task branch can't also be its merge target: \(branch).")
            }
        }
        return RepositoryWorktreeRecord(
            repositoryPath: repository,
            branch: branch.flatMap { $0.isEmpty ? nil : $0 } ?? "auto",
            worktreePath: repository,
            branchFrom: branchFrom,
            createdByPlayhouse: false,
            mergeTarget: mergeTarget,
            isPending: true
        )
    }

    static func preflightRemoval(_ record: RepositoryWorktreeRecord) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Can't mark this task Done because its worktree has uncommitted changes: \(record.worktreePath)")
        }
    }

    static func commitChanges(_ record: RepositoryWorktreeRecord, message: String) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try git(record.worktreePath, ["add", "-A"])
        _ = try git(record.worktreePath, ["commit", "-m", message])
    }

    static func publishBranch(_ record: RepositoryWorktreeRecord) throws {
        guard let remote = try resolvedRemote(record) else {
            throw BridgeCommandError(code: "operation_failed", message: "The task branch has no Git remote configured for publishing.")
        }
        _ = try git(record.worktreePath, ["push", "--set-upstream", remote, record.branch])
    }

    /// The remote the task branch publishes to: its configured remote, else origin.
    static func resolvedRemote(_ record: RepositoryWorktreeRecord) throws -> String? {
        let configuredRemote = try git(record.worktreePath, ["config", "--get", "branch.\(record.branch).remote"], allowFailure: true)
        let remotes = Set(try git(record.worktreePath, ["remote"]).output
            .split(whereSeparator: \.isNewline).map(String.init))
        let configuredName = configuredRemote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return remotes.contains(configuredName) ? configuredName : (remotes.contains("origin") ? "origin" : nil)
    }

    /// Fetches the task branch from its remote and reports how the local branch
    /// relates to it. FETCH_HEAD is left pointing at the remote branch so a
    /// following merge uses exactly the fetched commit.
    static func fetchRemoteBranchState(_ record: RepositoryWorktreeRecord) throws -> RemoteBranchSyncState {
        guard let remote = try resolvedRemote(record) else {
            return RemoteBranchSyncState(remote: nil, remoteBranchExists: false, aheadCount: 0, behindCount: 0)
        }
        let fetch = try git(record.worktreePath, ["fetch", "--quiet", remote, record.branch], allowFailure: true)
        guard fetch.status == 0 else {
            if fetch.output.localizedCaseInsensitiveContains("couldn't find remote ref") {
                return RemoteBranchSyncState(remote: remote, remoteBranchExists: false, aheadCount: 0, behindCount: 0)
            }
            throw BridgeCommandError(code: "operation_failed", message: fetch.output.isEmpty ? "Git couldn't fetch the task branch from \(remote)." : fetch.output)
        }
        let ahead = Int(try git(record.worktreePath, ["rev-list", "--count", "FETCH_HEAD..HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let behind = Int(try git(record.worktreePath, ["rev-list", "--count", "HEAD..FETCH_HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return RemoteBranchSyncState(remote: remote, remoteBranchExists: true, aheadCount: ahead, behindCount: behind)
    }

    /// Merges the branch commit the last fetch produced, leaving conflicts in the
    /// working tree for resolution. Status 1 means the merge stopped on conflicts.
    static func mergeFetchedRemoteBranch(_ record: RepositoryWorktreeRecord) throws {
        let result = try git(record.worktreePath, ["merge", "--no-commit", "--no-ff", "FETCH_HEAD"], allowFailure: true)
        guard result.status == 0 || result.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: result.output.isEmpty ? "Git couldn't merge the remote task branch." : result.output)
        }
    }

    static func hasChanges(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the branch holds commits its merge target lacks. GitHub rejects a
    /// pull request without any ("No commits between ..."). Without a configured
    /// merge target there is nothing to compare, so GitHub decides.
    static func hasCommitsAheadOfMergeTarget(_ record: RepositoryWorktreeRecord) throws -> Bool {
        guard record.mergeTarget?.isEmpty == false else { return true }
        let targetRef = try mergeTargetRef(record)
        let count = try git(record.worktreePath, ["rev-list", "--count", "\(targetRef)..HEAD"]).output
        return (Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) > 0
    }

    static func hasMergeConflicts(_ record: RepositoryWorktreeRecord) throws -> Bool {
        guard record.mergeTarget?.isEmpty == false else { return false }
        let targetRef = try mergeTargetRef(record)
        let merge = try git(record.worktreePath, ["merge-tree", "--write-tree", "HEAD", targetRef], allowFailure: true)
        guard merge.status == 0 || merge.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: merge.output.isEmpty ? "Git couldn't check the configured merge target." : merge.output)
        }
        return merge.status == 1
    }

    static func mergeTarget(_ record: RepositoryWorktreeRecord, target: String) throws {
        let targetRef = try mergeTargetRef(record)
        let result = try git(record.worktreePath, ["merge", "--no-commit", "--no-ff", targetRef], allowFailure: true)
        guard result.status == 0 || result.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: result.output.isEmpty ? "Git couldn't merge the target branch." : result.output)
        }
    }

    private static func mergeTargetRef(_ record: RepositoryWorktreeRecord) throws -> String {
        guard let target = record.mergeTarget, !target.isEmpty else {
            throw BridgeCommandError(code: "invalid_transition", message: "This repository has no configured merge target.")
        }
        let remotes = Set(try git(record.worktreePath, ["remote"]).output.split(whereSeparator: \.isNewline).map(String.init))
        let configured = try git(record.worktreePath, ["config", "--get", "branch.\(target).remote"], allowFailure: true)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remotes.contains(configured) ? configured : (remotes.contains("origin") ? "origin" : nil)
        if let remote {
            _ = try git(record.worktreePath, ["fetch", "--quiet", remote, target])
            return "FETCH_HEAD"
        }
        let localTarget = try git(record.worktreePath, ["rev-parse", "--verify", "refs/heads/\(target)"], allowFailure: true)
        guard localTarget.status == 0 else {
            throw BridgeCommandError(code: "operation_failed", message: "The configured merge target '\(target)' is not available locally or on a configured remote.")
        }
        return target
    }

    static func hasUnmergedFiles(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let result = try git(record.worktreePath, ["diff", "--name-only", "--diff-filter=U"])
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasMergeInProgress(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let result = try git(record.worktreePath, ["rev-parse", "--verify", "MERGE_HEAD"], allowFailure: true)
        return result.status == 0
    }

    static func removeAfterConfirmation(_ record: RepositoryWorktreeRecord) throws {
        guard record.createdByPlayhouse,
              FileManager.default.fileExists(atPath: record.worktreePath) else { return }
        _ = try git(record.repositoryPath, ["worktree", "remove", "--force", record.worktreePath])
    }

    static func remove(_ record: RepositoryWorktreeRecord) throws {
        try preflightRemoval(record)
        _ = try git(record.repositoryPath, ["worktree", "remove", record.worktreePath])
    }

    private struct ExistingWorktree { let path: String; let branch: String? }

    private static func worktrees(repository: String) throws -> [ExistingWorktree] {
        let output = try git(repository, ["worktree", "list", "--porcelain"]).output
        var result: [ExistingWorktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let path { result.append(ExistingWorktree(path: URL(fileURLWithPath: path).standardizedFileURL.path, branch: branch?.replacingOccurrences(of: "refs/heads/", with: ""))) }
            path = nil
            branch = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { flush() }
            else if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)) }
        }
        flush()
        return result
    }

    private struct DefaultBranches {
        let branchFrom: String
        let mergeTarget: String
        let hasLocalMergeTarget: Bool
    }

    private static func defaultBranchOptionsIfNeeded(
        repository: String,
        spec: RepositoryWorktreeSpec
    ) throws -> DefaultBranches? {
        let needsBranchFrom = spec.branchFrom?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let needsMergeTarget = spec.mergeTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard needsBranchFrom || needsMergeTarget else { return nil }
        return try defaultBranches(repository: repository)
    }

    private static func defaultBranches(repository: String) throws -> DefaultBranches {
        let output = try git(repository, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]).output
        let localBranches = Set(output.split(whereSeparator: \.isNewline).map(String.init))
        let remoteHead = try? git(repository, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = remoteHead?.replacingOccurrences(of: "refs/remotes/origin/", with: "")

        let branchFrom: String
        if localBranches.contains("master") {
            branchFrom = "master"
        } else if let remoteBranch, !remoteBranch.isEmpty {
            branchFrom = remoteBranch
        } else {
            branchFrom = try currentBranch(repository: repository)
        }

        let mergeTarget: String
        if let remoteBranch, localBranches.contains(remoteBranch) {
            mergeTarget = remoteBranch
        } else if localBranches.contains("main") {
            mergeTarget = "main"
        } else if localBranches.contains("master") {
            mergeTarget = "master"
        } else {
            mergeTarget = try currentBranch(repository: repository)
        }
        return DefaultBranches(
            branchFrom: branchFrom,
            mergeTarget: mergeTarget,
            hasLocalMergeTarget: localBranches.contains(mergeTarget)
        )
    }

    private static func currentBranch(repository: String) throws -> String {
        try git(repository, ["branch", "--show-current"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveBase(
        repository: String,
        requested: String?,
        defaults: DefaultBranches? = nil
    ) throws -> String {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.hasPrefix("-") else {
                throw BridgeCommandError(code: "invalid_argument", message: "Branch-from names can't begin with a hyphen.")
            }
            if try isCommit(repository: repository, base) { return base }
            if let remoteBase = try remoteBase(repository: repository, branch: base) { return remoteBase }
            throw BridgeCommandError(code: "invalid_argument", message: "Branch-from '\(base)' doesn't exist in \(repository) or on its remotes.")
        }
        return try (defaults ?? defaultBranches(repository: repository)).branchFrom
    }

    private static func isCommit(repository: String, _ ref: String) throws -> Bool {
        try git(repository, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], allowFailure: true).status == 0
    }

    /// Resolves a branch that isn't local to its remote-tracking ref, fetching it
    /// when the remote has it but it was never fetched. Origin is tried first.
    /// A name already qualified with a remote ("origin/feature") fetches that branch.
    private static func remoteBase(repository: String, branch: String) throws -> String? {
        let remotes = try git(repository, ["remote"]).output.split(whereSeparator: \.isNewline).map(String.init)
            .sorted { lhs, rhs in lhs == "origin" && rhs != "origin" }
        var candidates = remotes.map { (remote: $0, branch: branch) }
        if let qualified = remotes.first(where: { branch.hasPrefix("\($0)/") && branch.count > $0.count + 1 }) {
            candidates.insert((qualified, String(branch.dropFirst(qualified.count + 1))), at: 0)
        }
        var fetchFailure: String?
        for candidate in candidates {
            guard try git(repository, ["check-ref-format", "--branch", candidate.branch], allowFailure: true).status == 0 else { continue }
            let trackingRef = "refs/remotes/\(candidate.remote)/\(candidate.branch)"
            if try isCommit(repository: repository, trackingRef) { return "\(candidate.remote)/\(candidate.branch)" }
            let fetch = try git(
                repository,
                ["fetch", "--quiet", "--no-tags", candidate.remote, "+refs/heads/\(candidate.branch):\(trackingRef)"],
                allowFailure: true
            )
            if fetch.status == 0, try isCommit(repository: repository, trackingRef) {
                return "\(candidate.remote)/\(candidate.branch)"
            }
            // A remote that answered without the branch just lacks it; any other
            // failure (offline, auth) must not be reported as a missing branch.
            if fetch.status != 0, !fetch.error.localizedCaseInsensitiveContains("couldn't find remote ref") {
                fetchFailure = fetchFailure ?? "Git couldn't fetch '\(candidate.branch)' from \(candidate.remote): \(fetch.error.isEmpty ? "unknown error" : fetch.error)"
            }
        }
        if let fetchFailure {
            throw BridgeCommandError(code: "operation_failed", message: fetchFailure)
        }
        return nil
    }

    private static func resolveMergeTarget(
        repository: String,
        requested: String?,
        defaults: DefaultBranches? = nil
    ) throws -> String {
        guard let requested,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let branchOptions = try defaults ?? defaultBranches(repository: repository)
            let candidate = branchOptions.mergeTarget
            guard !candidate.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "Choose a local branch as the merge target for \(repository).")
            }
            guard branchOptions.hasLocalMergeTarget else {
                throw BridgeCommandError(code: "invalid_argument", message: "Merge target '\(candidate)' must name an existing local branch.")
            }
            return candidate
        }
        let candidate = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.hasPrefix("-") else {
            throw BridgeCommandError(code: "invalid_argument", message: "Merge target names can't begin with a hyphen.")
        }
        guard try git(repository, ["check-ref-format", "--branch", candidate], allowFailure: true).status == 0,
              try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], allowFailure: true).status == 0 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Merge target '\(candidate)' must name an existing local branch.")
        }
        return candidate
    }

    private static func managedPath(root: URL, repository: String, branch: String) -> URL {
        let name = URL(fileURLWithPath: repository).lastPathComponent
        var hash: UInt64 = 14695981039346656037
        for byte in repository.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let branchToken = branch.utf8.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
            .appendingPathComponent(branchToken, isDirectory: true)
    }

    private struct GitResult { let status: Int32; let output: String; var error: String = "" }

    private static func git(_ path: String, _ arguments: [String], allowFailure: Bool = false) throws -> GitResult {
        let candidates = (PlayhouseProcessEnvironment.current["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("git").path
        } + ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "Git couldn't be found. Install Git and try again.")
        }
        let result = try PlayhouseProcessRunner.run(
            executable: executable,
            arguments: ["-C", path] + arguments
        )
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.status == 0 || allowFailure else {
            throw BridgeCommandError(code: "operation_failed", message: detail.isEmpty ? "Git command failed." : detail)
        }
        return GitResult(status: result.status, output: text, error: detail)
    }
}

struct PlayhouseProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum PlayhouseProcessRunner {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outputData = Data()
        private var errorData = Data()

        func setOutput(_ data: Data) {
            lock.lock()
            outputData = data
            lock.unlock()
        }

        func setError(_ data: Data) {
            lock.lock()
            errorData = data
            lock.unlock()
        }

        func values() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (outputData, errorData)
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        directory: String? = nil
    ) throws -> PlayhouseProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = PlayhouseProcessEnvironment.current
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        let box = OutputBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setOutput(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setError(error.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.wait()
        process.waitUntilExit()
        let (stdout, stderr) = box.values()
        return PlayhouseProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum PlayhouseBackgroundOperation {
    /// Runs synchronous, possibly slow work (git, `gh`) off the main actor.
    /// `Task.detached` drops task-local values, so without restoring the
    /// calling request's environment and diagnostics scope here, this work
    /// would see the daemon's own bare process environment instead of its
    /// caller's (for example a worktree-relative `PATH` override, or a test
    /// harness's `PLAYHOUSE_E2E_*` fixture overrides).
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let requestContext = await PlayhouseRequestContext.capture()
        return try await Task.detached(priority: priority) {
            try await requestContext.run {
                try operation()
            }
        }.value
    }
}

@MainActor
struct PlayhouseWorktreeService {

    private func perform<T>(
        _ operation: String,
        record: RepositoryWorktreeRecord? = nil,
        fields extraFields: [String: String] = [:],
        body: () async throws -> T
    ) async throws -> T {
        var fields = extraFields
        fields["operation"] = operation
        if let record {
            fields["repositoryPath"] = record.repositoryPath
            fields["branch"] = record.branch
            fields["worktreePath"] = record.worktreePath
            fields["isPending"] = String(record.isPending)
            fields["createdByPlayhouse"] = String(record.createdByPlayhouse)
        }
        fields["operationID"] = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("git.operation.started", fields: fields)
        do {
            let result = try await body()
            var resultFields = fields
            resultFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            if let changed = result as? Bool { resultFields["hasChanges"] = String(changed) }
            PlayhouseDiagnostics.record("git.operation.succeeded", fields: resultFields)
            return result
        } catch {
            var failureFields = fields
            failureFields.merge(PlayhouseDiagnostics.errorFields(error)) { _, new in new }
            failureFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            PlayhouseDiagnostics.record("git.operation.failed", fields: failureFields)
            throw error
        }
    }

    func pendingRecord(spec: RepositoryWorktreeSpec) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.prepare", fields: ["repositoryPath": spec.repositoryPath]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.pendingRecord(spec: spec)
            }
        }
    }

    func resolve(
        spec: RepositoryWorktreeSpec,
        title: String,
        root: URL
    ) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.create", fields: [
            "repositoryPath": spec.repositoryPath,
            "branch": spec.branch ?? "auto",
            "branchFrom": spec.branchFrom ?? "",
            "mergeTarget": spec.mergeTarget ?? "",
            "managedRoot": root.path
        ]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.resolve(spec: spec, title: title, root: root)
            }
        }
    }

    func hasChanges(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("worktree.check_changes", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasChanges(record)
            }
        }
    }

    func hasMergeConflicts(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_conflicts", record: record, fields: ["mergeTarget": record.mergeTarget ?? ""]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasMergeConflicts(record)
            }
        }
    }

    func mergeTarget(_ record: RepositoryWorktreeRecord, target: String) async throws {
        try await perform("git.merge_target", record: record, fields: ["mergeTarget": target]) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.mergeTarget(record, target: target) }
        }
    }

    func hasUnmergedFiles(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_unmerged_files", record: record) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.hasUnmergedFiles(record) }
        }
    }

    func hasMergeInProgress(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_in_progress", record: record) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.hasMergeInProgress(record) }
        }
    }

    func remove(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.remove(record)
            }
        }
    }

    func removeAfterConfirmation(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove_after_confirmation", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.removeAfterConfirmation(record)
            }
        }
    }

    func commitChanges(_ record: RepositoryWorktreeRecord, message: String) async throws {
        try await perform("git.commit", record: record, fields: ["commitMessageBytes": String(message.utf8.count)]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.commitChanges(record, message: message)
            }
        }
    }

    func hasCommitsAheadOfMergeTarget(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.has_commits_ahead", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasCommitsAheadOfMergeTarget(record)
            }
        }
    }

    func publishBranch(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.publish_branch", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.publishBranch(record)
            }
        }
    }

    func fetchRemoteBranchState(_ record: RepositoryWorktreeRecord) async throws -> RemoteBranchSyncState {
        try await perform("git.fetch_branch_state", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.fetchRemoteBranchState(record)
            }
        }
    }

    func mergeFetchedRemoteBranch(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.merge_remote_branch", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.mergeFetchedRemoteBranch(record)
            }
        }
    }
}

/// How a task branch relates to the same branch on its publishing remote.
struct RemoteBranchSyncState: Sendable {
    let remote: String?
    let remoteBranchExists: Bool
    let aheadCount: Int
    let behindCount: Int
}

struct WorkspaceRootSelector: View {
    let parentFolderURL: URL?
    @Binding var roots: [URL]
    var displayNames: [String: String] = [:]
    @State private var repositories: [URL] = []
    @State private var searchText = ""
    @State private var isScanning = false

    private var filteredRepositories: [URL] {
        let available = repositories.filter { candidate in
            !roots.contains(where: { $0.standardizedFileURL.path == candidate.standardizedFileURL.path })
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.lastPathComponent.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Working folders")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: browseForFolders) {
                    Label("Browse…", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonHoverPointer()
                .nativeHelp("Browse folders")
                .buttonStyle(.bordered)
                .accessibilityIdentifier("browse-workspace-roots-button")
            }

            if roots.isEmpty {
                Text("Choose one or more folders. Git repositories under your parent folder appear as suggestions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(roots, id: \.standardizedFileURL.path) { root in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(displayNames[root.standardizedFileURL.path] ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("Remove \(displayNames[root.standardizedFileURL.path] ?? root.path)")
                            .accessibilityLabel("Remove \(displayNames[root.standardizedFileURL.path] ?? root.lastPathComponent)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            TextField("Search suggested repositories…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workspace-repository-search")

            if isScanning {
                ProgressView("Finding Git repositories…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            } else if filteredRepositories.isEmpty {
                Text(parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredRepositories, id: \.path) { repository in
                            Button {
                                add(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(repository.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Add repository \(repository.lastPathComponent)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                }
                .frame(maxHeight: 142)
                .background(WorkspaceTheme.panelBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: parentFolderURL?.path) {
            guard let parentFolderURL else {
                repositories = []
                return
            }
            isScanning = true
            repositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parentFolderURL.path).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }) ?? []
            isScanning = false
        }
    }

    private func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !roots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        roots.append(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose working folders"
        panel.message = "Choose one or more folders Codex should use as task context."
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = parentFolderURL
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                panel.urls.forEach(add)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct WorkspaceSettingsView: View {
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @State private var appearance = WorkspaceSettings.preferencesStore.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
    @State private var tokenUsageColorMax = WorkspaceSettingsManager().tokenUsageColorMax
    @State private var cpuUsageColorMax = WorkspaceSettingsManager().cpuUsageColorMax
    @State private var pickerError: String?
    @State private var tokenUsageError: String?
    @State private var cpuUsageError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { appearance },
                    set: { value in
                        do {
                            try WorkspaceSettingsManager().setAppearance(value)
                            appearance = value
                        } catch {
                            pickerError = error.localizedDescription
                        }
                    }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .accessibilityIdentifier("appearance-picker")
                .accessibilityValue(appearance)
            }
            Section("Token usage") {
                Text("A task card's dot warms from green to red as the task's token use approaches this total.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Red at")
                    TextField("Tokens", value: Binding(
                        get: { tokenUsageColorMax },
                        set: { value in
                            do {
                                try WorkspaceSettingsManager().setTokenUsageColorMax(value)
                                tokenUsageColorMax = value
                            } catch {
                                tokenUsageError = error.localizedDescription
                            }
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("token-usage-color-max-field")
                    Text("tokens")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Section("CPU usage") {
                Text("A running task's left-edge bar warms from green to red as its CPU use approaches this percentage. For Codex tasks, which share one app-server, that's the CPU of commands running in the task's worktree.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("Red at")
                    TextField("Percent", value: Binding(
                        get: { cpuUsageColorMax },
                        set: { value in
                            do {
                                try WorkspaceSettingsManager().setCPUUsageColorMax(value)
                                cpuUsageColorMax = value
                            } catch {
                                cpuUsageError = error.localizedDescription
                            }
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .accessibilityIdentifier("cpu-usage-color-max-field")
                    Text("%")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Section("Repository root") {
                Text("Choose the root folder that contains your repositories. Playhouse searches below it for repository suggestions, and a valid root is required before sending a conversation.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(parentFolderURL?.path ?? "No default parent folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No default parent folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    Spacer()
                    Button(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                    .buttonHoverPointer()
                        .nativeHelp("Choose repository root folder")
                        .accessibilityIdentifier("choose-default-parent-folder-button")
                    if parentFolderURL != nil {
                        Button("Clear") {
                            do {
                                try WorkspaceSettingsManager().setDefaultParentFolder(nil)
                                defaultParentFolderPath = ""
                            } catch {
                                pickerError = error.localizedDescription
                            }
                        }
                        .buttonHoverPointer()
                        .nativeHelp("Clear repository root folder")
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    Label("This folder is unavailable. Choose another parent folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                    Text("Changing this setting affects suggestions for new tasks. It does not change the working folders saved on existing tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                let preferences = WorkspaceSettings.preferencesStore
                preferences.synchronize()
                if let updatedAppearance = preferences.string(forKey: WorkspaceSettings.appearanceKey),
                   updatedAppearance != appearance {
                    appearance = updatedAppearance
                }
                let updatedMax = WorkspaceSettingsManager().tokenUsageColorMax
                if updatedMax != tokenUsageColorMax { tokenUsageColorMax = updatedMax }
                let updatedCPUMax = WorkspaceSettingsManager().cpuUsageColorMax
                if updatedCPUMax != cpuUsageColorMax { cpuUsageColorMax = updatedCPUMax }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .alert("Couldn't choose folder", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss folder error")
        } message: {
            Text(pickerError ?? "Please try again.")
        }
        .alert("Couldn't save token usage setting", isPresented: Binding(
            get: { tokenUsageError != nil },
            set: { if !$0 { tokenUsageError = nil } }
        )) {
            Button("OK", role: .cancel) { tokenUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss token usage setting error")
        } message: {
            Text(tokenUsageError ?? "Please try again.")
        }
        .alert("Couldn't save CPU usage setting", isPresented: Binding(
            get: { cpuUsageError != nil },
            set: { if !$0 { cpuUsageError = nil } }
        )) {
            Button("OK", role: .cancel) { cpuUsageError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss CPU usage setting error")
        } message: {
            Text(cpuUsageError ?? "Please try again.")
        }
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose repository root folder"
        panel.message = "Playhouse will search below this folder for repositories. A root folder is required before sending conversations."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            DispatchQueue.main.async {
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
    }
}

@MainActor
enum PlayhouseDiagnostics {
    private static var directoryOverride: URL?
    private static var ingressPendingBytes = 0
    private static var ingressDroppedEvents = 0
    nonisolated private static let writeLock = NSLock()
    nonisolated(unsafe) private static var logDescriptor: Int32 = -1
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1
    nonisolated(unsafe) private static var openedLockPath: String?
    nonisolated(unsafe) private static var openedLogPath: String?
    nonisolated(unsafe) private static var flushScheduled = false
    /// Buffered records keyed by where each was routed when recorded. One
    /// process can serve requests for different stores (the bridge daemon), so
    /// a flush must not move one request's records into another's log.
    nonisolated(unsafe) private static var bufferedEvents: [Destination: Data] = [:]
    nonisolated(unsafe) private static var pendingWriterBytes = 0
    nonisolated(unsafe) private static var droppedBufferedEvents = 0
    nonisolated(unsafe) private static var failedWriteCount = 0
    nonisolated(unsafe) private static var lastWriteFailure = ""
    nonisolated private static let totalLogLimit = 10 * 1024 * 1024
    nonisolated private static let perFileLimit = totalLogLimit / 2
    nonisolated private static let eventLimit = 512 * 1024
    nonisolated private static let batchLimit = 128 * 1024
    nonisolated private static let pendingWriterLimit = 2 * 1024 * 1024
    nonisolated private static let logger = Logger(subsystem: "com.playhouse.app", category: "diagnostics")
    nonisolated private static let writerQueue = DispatchQueue(label: "com.playhouse.diagnostics.writer", qos: .utility)

    static func useDataDirectory(_ path: String?) {
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let scope = PlayhouseRequestContext.diagnosticsScope else {
            directoryOverride = url
            return
        }
        scope.directoryOverride = url
        if scope.awaitingDirectory { releaseHeldRecords(of: scope) }
    }

    /// The store directory diagnostics route to: this request's own selection
    /// inside a bridge request, otherwise the process-wide one.
    static var currentDirectoryOverride: URL? {
        if let scope = PlayhouseRequestContext.diagnosticsScope { return scope.directoryOverride }
        return directoryOverride
    }

    private enum Destination: Hashable {
        case file(URL)
        case awaitingDirectory(UUID)
    }

    private static var logDestination: Destination {
        if let scope = PlayhouseRequestContext.diagnosticsScope, scope.awaitingDirectory {
            return .awaitingDirectory(scope.id)
        }
        return .file(logURL)
    }

    /// Sends the records a request made before choosing its store directory
    /// to that request's log; later records go there directly.
    private static func releaseHeldRecords(of scope: PlayhouseDiagnosticsScope) {
        scope.awaitingDirectory = false
        let target = logURL
        let held = Destination.awaitingDirectory(scope.id)
        writerQueue.async {
            if let records = bufferedEvents.removeValue(forKey: held) {
                bufferedEvents[.file(target), default: Data()].append(records)
            }
        }
    }

    static var logURL: URL {
        let directory: URL
        if let directoryOverride = currentDirectoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if PlayhouseAppIdentity.worktreeKey != nil,
                  let worktreeDirectory = try? PlayhouseAppIdentity.defaultDataDirectory() {
            directory = worktreeDirectory
        } else if let logsDirectory = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directory = logsDirectory.appendingPathComponent("Logs/Playhouse", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Playhouse", isDirectory: true)
        }
        return directory.appendingPathComponent("Diagnostics.jsonl")
    }

    static var storeURL: URL {
        let directory: URL
        if let directoryOverride = currentDirectoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if let supportDirectory = try? PlayhouseAppIdentity.defaultDataDirectory() {
            directory = supportDirectory
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Playhouse", isDirectory: true)
        }
        return directory.appendingPathComponent("Playhouse-v2.store")
    }

    static func storeContextFields(for storeURL: URL?) -> [String: String] {
        guard let storeURL else { return ["storePathAvailable": "false"] }

        let fileManager = FileManager.default
        let directoryURL = storeURL.deletingLastPathComponent()
        var fields = [
            "storePathAvailable": "true",
            "storePath": storeURL.standardizedFileURL.path,
            "storeDirectoryExists": String(fileManager.fileExists(atPath: directoryURL.path)),
            "storeDirectoryReadable": String(fileManager.isReadableFile(atPath: directoryURL.path)),
            "storeDirectoryWritable": String(fileManager.isWritableFile(atPath: directoryURL.path))
        ]
        appendFileSnapshot(storeURL, prefix: "storeFile", to: &fields)
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-wal"),
            prefix: "storeWAL",
            to: &fields
        )
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-shm"),
            prefix: "storeSHM",
            to: &fields
        )
        return fields
    }

    private static func appendFileSnapshot(_ url: URL, prefix: String, to fields: inout [String: String]) {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        fields["\(prefix)Exists"] = String(attributes != nil)
        fields["\(prefix)Readable"] = String(fileManager.isReadableFile(atPath: url.path))
        fields["\(prefix)Writable"] = String(fileManager.isWritableFile(atPath: url.path))
        if let size = attributes?[.size] as? NSNumber {
            fields["\(prefix)SizeBytes"] = size.stringValue
        }
        if let permissions = attributes?[.posixPermissions] as? NSNumber {
            fields["\(prefix)Permissions"] = String(format: "%04o", permissions.intValue)
        }
        if let modified = attributes?[.modificationDate] as? Date {
            fields["\(prefix)ModifiedAt"] = ISO8601DateFormatter().string(from: modified)
        }
    }

    static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated static func jsonStringOffMain<T: Encodable>(_ value: T) async -> String {
        let transfer = DiagnosticValueTransfer(value)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: jsonStringForDiagnostic(transfer.value))
            }
        }
    }

    nonisolated private static func jsonStringForDiagnostic<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(describing: value)
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated private static func sanitizeImagePayloads(_ value: Any) -> Any {
        if let string = value as? String, string.hasPrefix("data:image/") {
            let mime = string.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "unknown"
            return ["mime": mime, "encodedCharacterCount": string.count]
        }
        if let values = value as? [Any] {
            return values.map(sanitizeImagePayloads)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitizeImagePayloads)
        }
        return value
    }

    static func endBatch() async {
        if let scope = PlayhouseRequestContext.diagnosticsScope, scope.awaitingDirectory {
            releaseHeldRecords(of: scope)
        }
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let url = logURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                droppedBufferedEvents += ingressDrops
                flushBufferedEvents(at: url)
                continuation.resume()
            }
        }
    }

    static func recordAndFlush(_ event: String, fields: [String: String] = [:]) {
        record(event, fields: fields)
        let url = logURL
        writerQueue.sync {
            flushBufferedEvents(at: url)
        }
    }

    static func record(_ event: String, fields: [String: String] = [:]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: [:])
    }

    static func record(_ event: String, fields: [String: String] = [:], structuredFields: [String: Any]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: structuredFields)
    }

    private static func enqueue(_ originalEntry: [String: String], structuredFields originalStructuredFields: [String: Any]) {
        var entry = originalEntry
        var structuredFields = originalStructuredFields
        var estimatedBytes = estimateRetainedBytes(entry) + estimateRetainedBytes(structuredFields)
        if estimatedBytes > pendingWriterLimit {
            entry = [
                "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                "event": entry["event"] ?? "diagnostics.event",
                "process": ProcessInfo.processInfo.processName,
                "processID": String(ProcessInfo.processInfo.processIdentifier),
                "recording": "omitted_event_larger_than_writer_queue_limit",
                "originalByteCount": String(estimatedBytes)
            ]
            structuredFields = [:]
            estimatedBytes = entry.reduce(into: 0) { total, pair in
                total += pair.key.utf8.count + pair.value.utf8.count + 8
            }
        }
        guard ingressPendingBytes + estimatedBytes <= pendingWriterLimit else {
            ingressDroppedEvents += 1
            return
        }
        ingressPendingBytes += estimatedBytes
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let destination = logDestination
        let transfer = DiagnosticValueTransfer(structuredFields)
        writerQueue.async {
            droppedBufferedEvents += ingressDrops
            var encodedEntry = entry
            for (key, value) in transfer.value {
                encodedEntry[key] = jsonString(value)
            }
            appendSerializedEvent(encodedEntry, at: destination)
            Task { @MainActor in
                ingressPendingBytes = max(0, ingressPendingBytes - estimatedBytes)
            }
        }
    }

    nonisolated private static func estimateRetainedBytes(_ value: Any, limit: Int = pendingWriterLimit) -> Int {
        let overLimit = limit + 1
        if let string = value as? String { return min(string.utf8.count, overLimit) }
        if let dictionary = value as? [String: String] {
            var total = 0
            for (key, value) in dictionary {
                total += key.utf8.count + min(value.utf8.count, overLimit) + 8
                if total > limit { return overLimit }
            }
            return total
        }
        if let dictionary = value as? [String: Any] {
            var total = 0
            for (key, nestedValue) in dictionary {
                total += key.utf8.count + 8
                if total > limit { return overLimit }
                total += estimateRetainedBytes(nestedValue, limit: limit - total)
                if total > limit { return overLimit }
            }
            return total
        }
        if let values = value as? [Any] {
            var total = 0
            for nestedValue in values {
                total += estimateRetainedBytes(nestedValue, limit: limit - total) + 4
                if total > limit { return overLimit }
            }
            return total
        }
        if value is NSNull { return 4 }
        return min(16, overLimit)
    }

    nonisolated private static func appendSerializedEvent(_ originalEntry: [String: String], at url: Destination) {
        var entry = originalEntry
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if data.count + 1 > eventLimit {
            guard data.count <= perFileLimit else {
                entry = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "event": originalEntry["event"] ?? "diagnostics.event",
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier),
                    "recording": "omitted_event_larger_than_per_file_limit",
                    "originalByteCount": String(data.count + 1)
                ]
                guard let compactData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
                data = compactData
                data.append(0x0A)
                buffer(data, at: url)
                return
            }
            let payload = data.base64EncodedString()
            let payloadChunkSize = eventLimit / 2
            let chunks = stride(from: 0, to: payload.count, by: payloadChunkSize).map { offset in
                let start = payload.index(payload.startIndex, offsetBy: offset)
                let end = payload.index(start, offsetBy: min(payloadChunkSize, payload.distance(from: start, to: payload.endIndex)))
                return String(payload[start..<end])
            }
            for (index, chunk) in chunks.enumerated() {
                let chunkEntry: [String: String] = [
                    "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                    "event": "session.payload.chunk",
                    "payloadEvent": originalEntry["event"] ?? "diagnostics.event",
                    "payloadEncoding": "base64-json",
                    "chunkIndex": String(index),
                    "chunkCount": String(chunks.count),
                    "payload": chunk,
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier)
                ]
                guard var chunkData = try? JSONSerialization.data(withJSONObject: chunkEntry, options: [.sortedKeys]) else { continue }
                chunkData.append(0x0A)
                buffer(chunkData, at: url)
            }
            return
        }
        data.append(0x0A)
        buffer(data, at: url)
    }

    nonisolated private static func buffer(_ data: Data, at destination: Destination) {
        bufferedEvents[destination, default: Data()].append(data)
        if bufferedEvents.values.reduce(0, { $0 + $1.count }) >= batchLimit {
            flushBufferedEvents()
        } else if !flushScheduled {
            flushScheduled = true
            writerQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                flushScheduled = false
                flushBufferedEvents()
            }
        }
    }

    /// Writes every record routed to a log so far to that log; records still
    /// waiting for their request's store directory stay buffered. `url` only
    /// receives a pending loss report when nothing else is written.
    nonisolated private static func flushBufferedEvents(at url: URL? = nil) {
        var files: [(URL, Data)] = []
        for (destination, data) in bufferedEvents {
            if case .file(let fileURL) = destination { files.append((fileURL, data)) }
        }
        for (fileURL, _) in files { bufferedEvents.removeValue(forKey: .file(fileURL)) }
        if files.isEmpty {
            guard droppedBufferedEvents > 0 || failedWriteCount > 0 else { return }
            write(Data(), reportingLossTo: url ?? URL(fileURLWithPath: "/"))
            return
        }
        for (targetURL, data) in files {
            write(data, reportingLossTo: targetURL)
        }
    }

    nonisolated private static func write(_ events: Data, reportingLossTo targetURL: URL) {
        var data = events
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: targetURL.deletingLastPathComponent().path
            )
        } catch {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("Playhouse couldn't create diagnostics directory: \(error.localizedDescription, privacy: .private)")
            return
        }
        let lossLockPath = targetURL.path + ".loss.lock"
        let lossLockDescriptor = open(lossLockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        guard lossLockDescriptor >= 0 else {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("Playhouse couldn't open diagnostics loss-state lock: \(String(cString: strerror(errno)), privacy: .private)")
            return
        }
        _ = fchmod(lossLockDescriptor, S_IRUSR | S_IWUSR)
        guard flock(lossLockDescriptor, LOCK_EX) == 0 else {
            let lockError = String(cString: strerror(errno))
            close(lossLockDescriptor)
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("Playhouse couldn't lock diagnostics loss state: \(lockError, privacy: .private)")
            return
        }
        defer {
            _ = flock(lossLockDescriptor, LOCK_UN)
            close(lossLockDescriptor)
        }
        if !data.isEmpty && pendingWriterBytes + data.count > pendingWriterLimit {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            return
        }
        let persistedLoss = readPendingLoss(at: targetURL)
        let reportedDrops = (persistedLoss?.droppedEventCount ?? 0) + droppedBufferedEvents
        let reportedFailures = (persistedLoss?.failedWriteCount ?? 0) + failedWriteCount
        let reportedError = lastWriteFailure
            .isEmpty ? (persistedLoss?.lastWriteError ?? "") : lastWriteFailure
        let reportsLoss = reportedDrops > 0 || reportedFailures > 0
        var includedLossMarker = false
        if reportsLoss,
           let marker = try? JSONSerialization.data(withJSONObject: [
               "timestamp": ISO8601DateFormatter().string(from: Date()),
               "event": "diagnostics.writer.loss",
                "droppedEventCount": String(reportedDrops),
               "failedWriteCount": String(reportedFailures),
               "lastWriteError": reportedError
           ], options: [.sortedKeys]) {
            var markerData = marker
            markerData.append(0x0A)
            if pendingWriterBytes + data.count + markerData.count <= pendingWriterLimit {
                data.insert(contentsOf: markerData, at: 0)
                includedLossMarker = true
            }
        }
        pendingWriterBytes += data.count
        if let error = write(data, at: targetURL) {
            let saved = persistPendingLoss(
                droppedEventCount: reportedDrops,
                failedWriteCount: reportedFailures + 1,
                lastWriteError: error,
                at: targetURL
            )
            if saved {
                droppedBufferedEvents = 0
                failedWriteCount = 0
                lastWriteFailure = ""
            } else {
                failedWriteCount += 1
                lastWriteFailure = error
            }
        } else if reportsLoss && includedLossMarker {
            droppedBufferedEvents = 0
            failedWriteCount = 0
            lastWriteFailure = ""
            try? FileManager.default.removeItem(at: pendingLossURL(for: targetURL))
        }
        pendingWriterBytes = max(0, pendingWriterBytes - data.count)
    }

    private struct PendingLoss: Decodable {
        let droppedEventCount: Int
        let failedWriteCount: Int
        let lastWriteError: String
    }

    nonisolated private static func pendingLossURL(for url: URL) -> URL {
        url.appendingPathExtension("loss")
    }

    nonisolated private static func readPendingLoss(at url: URL) -> PendingLoss? {
        guard let data = try? Data(contentsOf: pendingLossURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(PendingLoss.self, from: data)
    }

    nonisolated private static func persistPendingLoss(
        droppedEventCount: Int,
        failedWriteCount: Int,
        lastWriteError: String,
        at url: URL
    ) -> Bool {
        let state: [String: Any] = [
            "droppedEventCount": droppedEventCount,
            "failedWriteCount": failedWriteCount,
            "lastWriteError": lastWriteError
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return false }
        let stateURL = pendingLossURL(for: url)
        do {
            try data.write(to: stateURL, options: .atomic)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            } catch {
                logger.error("Playhouse couldn't secure diagnostics loss state: \(error.localizedDescription, privacy: .private)")
            }
            return true
        } catch {
            logger.error("Playhouse couldn't persist diagnostics loss state: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    nonisolated private static func write(_ data: Data, at url: URL) -> String? {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            let lockPath = url.path + ".lock"
            if openedLockPath != lockPath {
                if lockDescriptor >= 0 { close(lockDescriptor) }
                lockDescriptor = -1
                openedLockPath = lockPath
            }
            if lockDescriptor < 0 {
                lockDescriptor = open(lockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
                guard lockDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard flock(lockDescriptor, LOCK_EX) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }
            try rotateLogIfNeeded(for: data.count, at: url)
            var descriptorInfo = stat()
            var pathInfo = stat()
            let descriptorExists = logDescriptor >= 0 && fstat(logDescriptor, &descriptorInfo) == 0
            let pathExists = lstat(url.path, &pathInfo) == 0
            let descriptorMatchesPath = descriptorExists && pathExists
                && descriptorInfo.st_dev == pathInfo.st_dev
                && descriptorInfo.st_ino == pathInfo.st_ino
            if openedLogPath != url.path || !descriptorMatchesPath {
                if logDescriptor >= 0 { close(logDescriptor) }
                logDescriptor = -1
                openedLogPath = url.path
            }
            if logDescriptor < 0 {
                logDescriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard logDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var fileInfo = stat()
            guard fstat(logDescriptor, &fileInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let originalSize = fileInfo.st_size
            var writeFailureErrno = EIO
            let writeResult = data.withUnsafeBytes { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(logDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else {
                        writeFailureErrno = errno
                        return false
                    }
                    offset += written
                }
                return true
            }
            guard writeResult else {
                _ = ftruncate(logDescriptor, originalSize)
                close(logDescriptor)
                logDescriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: writeFailureErrno) ?? .EIO)
            }
            return nil
        } catch {
            logger.error("Playhouse couldn't write diagnostics: \(error.localizedDescription, privacy: .private)")
            return error.localizedDescription
        }
    }

    nonisolated private static func rotateLogIfNeeded(for incomingBytes: Int, at url: URL) throws {
        let previousURL = url.appendingPathExtension("1")
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let previousSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if previousSize > perFileLimit || currentSize + previousSize + incomingBytes > totalLogLimit {
            try? FileManager.default.removeItem(at: previousURL)
        }
        guard currentSize + incomingBytes > perFileLimit else { return }

        if logDescriptor >= 0 {
            close(logDescriptor)
            logDescriptor = -1
        }
        try? FileManager.default.removeItem(at: previousURL)
        if currentSize > 0 {
            try FileManager.default.moveItem(at: url, to: previousURL)
        }
        openedLogPath = nil

        // The two files are each bounded to half the total allowance.
        // This also trims an older generation immediately during rotation.
        let rotatedSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if rotatedSize > perFileLimit { try FileManager.default.removeItem(at: previousURL) }
    }

    static func errorFields(_ error: Error, includeUserInfoDetails: Bool = false) -> [String: String] {
        var fields: [String: String] = [:]
        fields["errorDescription"] = error.localizedDescription
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            let prefix = "error\(depth)"
            fields["\(prefix)Domain"] = current.domain
            fields["\(prefix)Code"] = String(current.code)
            fields["\(prefix)Description"] = String(current.localizedDescription.prefix(4_096))
            let userInfoKeys = current.userInfo.keys.map(String.init(describing:)).sorted()
            fields["\(prefix)UserInfoKeys"] = userInfoKeys.joined(separator: ",")
            fields["\(prefix)UserInfoKeyCount"] = String(userInfoKeys.count)
            if let reason = current.localizedFailureReason { fields["\(prefix)Reason"] = reason }
            if includeUserInfoDetails {
                let diagnosticUserInfo = current.userInfo
                    .filter { $0.key != NSUnderlyingErrorKey }
                    .reduce(into: [String: Any]()) { result, item in
                        result[item.key] = diagnosticUserInfoValue(item.value)
                    }
                if let data = try? JSONSerialization.data(withJSONObject: diagnosticUserInfo, options: [.sortedKeys]),
                   let summary = String(data: data, encoding: .utf8) {
                    fields["\(prefix)UserInfo"] = String(summary.prefix(8_192))
                    fields["\(prefix)UserInfoTruncated"] = String(summary.utf8.count > 8_192)
                }
                if let debugDescription = current.userInfo["NSDebugDescription"] as? String {
                    fields["\(prefix)DebugDescription"] = String(debugDescription.prefix(4_096))
                }
                if let filePath = current.userInfo[NSFilePathErrorKey] as? String {
                    fields["\(prefix)FilePath"] = String(filePath.prefix(4_096))
                }
                if let recoverySuggestion = current.localizedRecoverySuggestion {
                    fields["\(prefix)RecoverySuggestion"] = String(recoverySuggestion.prefix(2_048))
                }
                if let failingURL = current.userInfo["NSURLErrorKey"] as? URL {
                    var components = URLComponents(url: failingURL, resolvingAgainstBaseURL: false)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? failingURL.path
                } else if let failingURL = current.userInfo["NSURLErrorKey"] as? String {
                    var components = URLComponents(string: failingURL)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? String(failingURL.prefix(4_096))
                }
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return fields
    }

    private static func diagnosticUserInfoValue(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 3 else { return "<nested-value-truncated>" }
        if let string = value as? String { return String(string.prefix(4_096)) }
        if let number = value as? NSNumber { return number }
        if let url = value as? URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            return components?.string ?? url.path
        }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = value as? Data { return ["byteCount": data.count] }
        if let error = value as? NSError {
            return ["domain": error.domain, "code": error.code, "description": String(error.localizedDescription.prefix(4_096))]
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().prefix(32).reduce(into: [String: Any]()) { result, key in
                if let nested = dictionary[key] {
                    result[key] = diagnosticUserInfoValue(nested, depth: depth + 1)
                }
            }
        }
        if let values = value as? [Any] {
            return values.prefix(32).map { diagnosticUserInfoValue($0, depth: depth + 1) }
        }
        return ["type": String(reflecting: type(of: value))]
    }

    static func errorFields(_ error: Error, redacting values: [String]) -> [String: String] {
        var fields = errorFields(error, includeUserInfoDetails: true)
        let secrets = values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !secrets.isEmpty else { return fields }

        let redactableFields = ["errorDescription"] + (0..<5).flatMap { index in
            ["Description", "Reason", "UserInfo", "DebugDescription", "FilePath", "RecoverySuggestion", "URL"].map {
                "error\(index)\($0)"
            }
        }
        for key in redactableFields {
            guard var value = fields[key] else { continue }
            for secret in secrets {
                value = value.replacingOccurrences(of: secret, with: "[redacted]")
            }
            fields[key] = value
        }
        return fields
    }
}

private struct DiagnosticValueTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

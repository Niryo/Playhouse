import Foundation
import AppKit
import SwiftData
import Darwin

extension ClaudeCodeClient {
    static func reportCommand(name: String, input: [String: Any]) -> TaskProgressReportInstructions.ReportCommand? {
        guard name == "Bash", let command = input["command"] as? String else { return nil }
        return TaskProgressReportInstructions.reportCommand(in: command)
    }

    static func activity(toolID: String, name: String, input: [String: Any], status: String, turnID: String?) -> ConversationActivity {
        var activity = baseActivity(toolID: toolID, name: name, input: input, status: status, turnID: turnID)
        guard activity.isTimelineToolCall else { return activity }
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            activity.summary = string("description")
            activity.input = string("command").map { String($0.prefix(ConversationActivity.timelineInputLimit)) }
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read":
            activity.summary = string("file_path") ?? string("notebook_path")
        case "Grep", "Glob":
            activity.summary = [string("pattern"), string("path")].compactMap { $0 }.joined(separator: " in ")
        case "WebSearch":
            activity.summary = string("query")
        case "WebFetch":
            activity.summary = string("url")
        default:
            // MCP and other tools keep their arguments and raw results private.
            break
        }
        return activity
    }

    static func baseActivity(toolID: String, name: String, input: [String: Any], status: String, turnID: String?) -> ConversationActivity {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            let command = string("command") ?? ""
            return ConversationActivity(id: toolID, title: command.isEmpty ? "Running command" : "Running \(command)", detail: string("description") ?? "", status: status, tool: name, turnID: turnID)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = string("file_path") ?? string("notebook_path") ?? ""
            return ConversationActivity(id: toolID, title: "Editing 1 file", detail: path, status: status, tool: name, turnID: turnID)
        case "Read":
            return ConversationActivity(id: toolID, title: "Reading \(string("file_path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file")", detail: string("file_path") ?? "", status: status, tool: name, turnID: turnID)
        case "Grep", "Glob":
            return ConversationActivity(id: toolID, title: "Searching files", detail: string("pattern") ?? "", status: status, tool: name, turnID: turnID)
        case "WebSearch":
            return ConversationActivity(id: toolID, title: "Searching the web", detail: string("query") ?? "", status: status, tool: name, turnID: turnID)
        case "WebFetch":
            return ConversationActivity(id: toolID, title: "Fetching a web page", detail: string("url") ?? "", status: status, tool: name, turnID: turnID)
        case "Task", "Agent":
            let agentType = string("subagent_type") ?? "general-purpose"
            let spaced = agentType.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return ConversationActivity(
                id: toolID, title: spaced.prefix(1).uppercased() + spaced.dropFirst(),
                detail: [agentType, string("description")].compactMap { $0 }.joined(separator: "\n"),
                status: status, childThreadID: toolID, agentPath: agentType, model: string("model"), turnID: turnID
            )
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? ""
                let tool = parts.dropFirst().joined(separator: "__")
                return ConversationActivity(
                    id: toolID, title: "MCP · \(tool.isEmpty ? "Tool" : tool)",
                    detail: server.isEmpty ? "" : "Server · \(server)", status: status,
                    toolKind: "mcp", server: server, tool: tool, turnID: turnID
                )
            }
            return ConversationActivity(id: toolID, title: "Tool · \(name)", detail: "", status: status, toolKind: "dynamic", tool: name, turnID: turnID)
        }
    }

    nonisolated static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func classifyFailure(_ error: ClientError, text: String) -> Error {
        let normalized = text.lowercased()
        if normalized.contains("/login") || normalized.contains("not logged in") || normalized.contains("invalid api key")
            || normalized.contains("authentication") || normalized.contains("oauth token") {
            return ClientError.authentication(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return error
    }

    static func verifyVersion(_ version: String?) throws {
        guard let version else { return }
        let current = version.split(separator: " ").first.map(String.init) ?? version
        if current.compare(minimumVersion, options: .numeric) == .orderedAscending {
            throw ClientError.unsupportedVersion(current)
        }
    }

    var executablePath: String? {
        if executableOverride == ConversationProviderFixture.notInstalledOverride { return nil }
        return executableOverride ?? Self.findExecutable()
    }

    static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let pathEntries = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path }
        let common = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"
        ]
        return (pathEntries + common).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        paths.append(contentsOf: ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

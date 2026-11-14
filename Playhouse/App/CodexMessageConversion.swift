import Foundation
import AppKit
import SwiftData
import Darwin

extension CodexAppServerClient {
    static func chatMessage(from entry: [String: Any]) -> ConversationMessage? {
        guard let item = entry["item"] as? [String: Any],
              let itemID = item["id"] as? String,
              let type = item["type"] as? String else {
            return nil
        }

        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = ConversationHandoff.stripContext(from: content.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined())
            let images = content.compactMap { part -> String? in
                guard part["type"] as? String == "image" else { return nil }
                return part["url"] as? String ?? part["image_url"] as? String
            }
            guard !text.isEmpty || !images.isEmpty else { return nil }
            return ConversationMessage(id: itemID, role: .user, text: text, imageDataURLs: images, turnID: entry["turnId"] as? String, provider: .codex, createdAt: messageTimestamp(entry: entry, item: item))
        case "agentMessage", "plan":
            let text = LeakedTurnOutcome.visibleText(item["text"] as? String ?? "")
            let questions = type == "agentMessage" && item["delivery"] as? String == "async"
                ? asyncQuestions(from: item) : nil
            guard !text.isEmpty || questions != nil else { return nil }
            return ConversationMessage(id: itemID, role: .assistant, text: text,
                                    phase: type == "plan" ? "final_answer" : item["phase"] as? String,
                                    turnID: entry["turnId"] as? String,
                                    asyncQuestions: questions,
                                    provider: .codex,
                                    createdAt: messageTimestamp(entry: entry, item: item))
        default:
            return nil
        }
    }

    /// Thread items the conversation timeline shows as tool calls.
    static let timelineToolItemTypes: Set<String> = [
        "commandExecution", "fileChange", "webSearch", "imageView", "mcpToolCall", "dynamicToolCall",
    ]

    static func messageTimestamp(entry: [String: Any], item: [String: Any]) -> Date? {
        for value in [entry["timestamp"], entry["createdAt"], item["timestamp"], item["createdAt"]] {
            if let date = value as? Date { return date }
            if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
            if let string = value as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: string) { return date }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) { return date }
            }
        }
        return nil
    }

    static func asyncQuestions(from item: [String: Any]) -> [ConversationAsyncQuestion]? {
        guard let rawQuestions = item["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap { raw -> ConversationAsyncQuestion? in
            guard let title = raw["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ConversationAsyncQuestion(title: title, options: raw["options"] as? [String])
        }
        return questions.isEmpty ? nil : questions
    }

    static func turnKey(threadID: String, turnID: String) -> String {
        "\(threadID):\(turnID)"
    }

    static func turnFailureDescription(_ turn: [String: Any]) -> String {
        if let error = turn["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return turnFailureDescription(message)
            }
            if JSONSerialization.isValidJSONObject(error),
               let data = try? JSONSerialization.data(withJSONObject: error),
               let detail = String(data: data, encoding: .utf8) {
                return "Codex couldn't complete this turn: \(detail)"
            }
        }
        return "Codex couldn't complete this turn. Check your CLI sign-in and model access, then try again."
    }

    static func turnFailureDescription(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains(Self.modelID) &&
            (normalized.contains("not supported") || normalized.contains("unsupported") ||
                normalized.contains("not available") || normalized.contains("unavailable")) {
            return "Codex Luna (\(Self.modelID)) isn't available to the current Codex sign-in. Playhouse didn't switch models. Sign in with an account or provider that supports this model, then try again."
        }
        return message
    }

    static func error(forServerMessage message: String, method: String? = nil) -> Error {
        let normalized = message.lowercased()
        let isMissedSteerTurn = method == "turn/steer" && (
            normalized == "no active turn to steer" ||
                (normalized.contains("expected active turn id") && normalized.contains("but found")) ||
                (normalized.contains("expected turn id") && normalized.contains("stale"))
        )
        if isMissedSteerTurn {
            return ClientError.staleTurn(message)
        }
        if normalized.contains("unauthorized") || normalized.contains("authentication") ||
            normalized.contains("not logged in") || normalized.contains("sign in") ||
            normalized.contains("401") {
            return ClientError.authentication(message)
        }
        if normalized.contains("model") &&
            (normalized.contains("not found") || normalized.contains("unavailable") || normalized.contains("unknown") ||
                normalized.contains("not supported") || normalized.contains("unsupported")) {
            return ClientError.server("Codex couldn't use \(Self.modelID): \(message). Playhouse won't switch models.")
        }
        return ClientError.server(message)
    }

    static var isInstalled: Bool { findCodexExecutable(override: nil) != nil }

    static func findCodexExecutable(override: String?) -> String? {
        if override == ConversationProviderFixture.notInstalledOverride { return nil }
        if let override, FileManager.default.isExecutableFile(atPath: override) { return override }
        let home = NSHomeDirectory()
        let commonPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
        let pathEntries = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }

        for candidate in pathEntries + commonPaths {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

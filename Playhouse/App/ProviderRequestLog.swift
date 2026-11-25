import CryptoKit
import Foundation

// Rebuilds what each model request of a task was sent, item by item, from the
// provider's own session files, so a task's token map can name what filled
// its context rather than only how much the turn cost.
//
// Claude Code logs its requests delta-encoded in `<session>.jsonl`:
// `api-request-shape` holds the system prompt and tool definitions once,
// `api-request-blob` holds each message once by hash, and each `api-request`
// is the first `keep` messages of its `base` request plus its `tail` blobs. A
// message the transcript already holds gets no blob line: its hash is the
// SHA-256 of its `{role, content}` as sorted-key JSON, built from the `user`
// line (or a run of user lines sent as one message) or from the `assistant`
// lines that share a message ID. An `assistant` line's `requestRef` names the
// request its billed usage belongs to.
//
// Codex logs `rollout-*-<thread>.jsonl`: the base instructions, then every
// response item in order, one `token_usage_record` per model request, and a
// `compacted` line whose `replacement_history` is the whole context after a
// compaction. Codex resends the whole history on every request, so a request
// was sent the instructions plus every item before its own output. Codex does
// not save its tool definitions; they show as one measured hidden-overhead item.
//
// OpenCode's server lists a session's messages, which Playhouse writes to
// `opencode-request-logs/<session>.jsonl` one per line (`OpenCodeRequestLog`).
// Each assistant message is one model request, sent every message before it
// since the last compaction, whose summary then stands for what came before.
// OpenCode returns neither its system prompt nor its tool definitions; like
// Codex's, they show as one measured hidden-overhead item.

/// Where each provider keeps its session files.
struct ProviderSessionHomes: Sendable, Equatable {
    var claudeConfigDirectory: String
    var codexHome: String

    /// An unset or empty override falls back to the provider's own default, as its client does.
    static func resolve(claudeConfigDirectory: String?, codexHome: String?) -> ProviderSessionHomes {
        let environment = PlayhouseProcessEnvironment.current
        func present(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        return ProviderSessionHomes(
            claudeConfigDirectory: present(claudeConfigDirectory) ?? present(environment["CLAUDE_CONFIG_DIR"]) ?? NSHomeDirectory() + "/.claude",
            codexHome: present(codexHome) ?? present(environment["CODEX_HOME"]) ?? NSHomeDirectory() + "/.codex"
        )
    }
}

/// What one item of a request's context is.
enum ProviderContextKind: String, Codable, Sendable {
    case systemPrompt
    case toolDefinition
    case hiddenOverhead
    case systemReminder
    case userText
    case assistantText
    case thinking
    case toolCall
    case toolResult
    case image
    case other

    /// Sent with every request whatever the conversation did, rather than added by a turn.
    var isFixedOverhead: Bool { self == .systemPrompt || self == .toolDefinition || self == .hiddenOverhead }
}

/// A key or index on the way from a log line's JSON object to one item.
enum ProviderJSONPathComponent: Sendable {
    case key(String)
    case index(Int)
}

/// Where an item's content lives, so its full text is read from the file on demand.
struct ProviderContextLocation: Sendable {
    let offset: UInt64
    let length: Int
    let path: [ProviderJSONPathComponent]
}

/// One content block (Claude) or response item (Codex) the model was sent.
struct ProviderContextItem: Sendable {
    let id: Int
    let kind: ProviderContextKind
    let role: String
    var label: String
    var server: String?
    /// How an item's share of a measured token delta is weighed.
    let weight: Int
    /// Length of the item's text in Unicode scalars.
    let textLength: Int
    let preview: String
    let contentKey: Int
    let location: ProviderContextLocation?
    /// The call ID a tool call declares or a tool result answers.
    let callID: String?
    var callItemID: Int?
    var tokens = 0
    var requests = 0
    var inFinalTranscript = false
}

/// One model request's billed usage.
struct ProviderRequestUsage: Sendable {
    let timestamp: String?
    /// Everything the request was sent: uncached input plus cache reads and writes.
    let contextTokens: Int
    let cacheReadTokens: Int
    /// `nil` where the provider does not report cache writes (Codex).
    let cacheWriteTokens: Int?
    let outputTokens: Int
}

/// One model request as its log records it: every item it was sent, in order.
struct ProviderSentRequest: Sendable {
    let timestamp: String?
    let querySource: String?
    /// Item IDs in the order they were sent; an item sent twice appears twice.
    let items: [Int]
    /// Claude: how many of the items each message holds, after the system
    /// prompt parts and tool definitions that lead the request.
    let messageLengths: [Int]
    /// Claude: messages the request names by hash that no line of the log holds.
    let missingMessages: Int
    /// Claude: the request names a system prompt and tools shape no line of the log holds.
    let missingShape: Bool
    let usage: ProviderRequestUsage?
    /// Claude: the `api-request` line, which holds the request's parameters.
    let line: ProviderContextLocation?
    /// Whether a compaction dropped history the request before it was sent.
    var compacted = false
}

/// The span of one turn: the requests sent from `start` up to, not including, `end`
/// (`nil` when no later turn has started).
struct ProviderRequestWindow: Equatable, Sendable {
    let start: Date
    let end: Date?

    func contains(_ date: Date) -> Bool {
        date >= start && end.map { date < $0 } ?? true
    }

    /// A request with no timestamp cannot be placed in any turn.
    func contains(timestamp: String?) -> Bool {
        timestamp.flatMap(Self.date).map(contains) ?? false
    }

    /// Both providers write ISO 8601 timestamps, with or without fractional seconds.
    static func date(_ timestamp: String) -> Date? {
        (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(timestamp, strategy: Date.ISO8601FormatStyle()))
    }
}

/// Everything one agent (a session's main agent or one subagent) was sent.
struct ProviderAgentLog: Sendable {
    let provider: ConversationProvider
    let file: URL
    /// The file the log was parsed from (its file number): a file replaced since (OpenCode's,
    /// rewritten at every model step) no longer holds its items at their offsets.
    var fileNumber: Int?
    var items: [ProviderContextItem] = []
    var requests: [ProviderRequestUsage] = []
    /// Every request the log records, measured or not, in the order it was made.
    var sent: [ProviderSentRequest] = []
    /// Item IDs of the last request's context, in the order they were sent.
    var finalTranscript: [Int] = []
    /// Index in `sent` of the request `finalTranscript` was read from.
    var finalRequest: Int?
    /// Model requests the log records, measured or not.
    var sentRequests = 0
    var compactions = 0

    var isAvailable: Bool { !requests.isEmpty }
    var sentTokens: Int { requests.reduce(0) { $0 + $1.contextTokens } }
    var finalTranscriptTokens: Int { finalTranscript.reduce(0) { $0 + items[$1].tokens } }

    /// Only the requests one turn made, numbered from 1 within the turn. Items keep their IDs
    /// and the sizes the whole log measured (an item's size does not depend on which request
    /// is looked at), but count only the turn's requests, and the final transcript is the
    /// turn's last request on the conversation's own source.
    func within(_ window: ProviderRequestWindow) -> ProviderAgentLog {
        let kept = sent.indices.filter { window.contains(timestamp: sent[$0].timestamp) }
        var log = ProviderAgentLog(provider: provider, file: file, fileNumber: fileNumber)
        log.sent = kept.map { sent[$0] }
        log.requests = log.sent.compactMap(\.usage)
        log.sentRequests = kept.count
        log.compactions = log.sent.filter(\.compacted).count
        var items = items
        for index in items.indices {
            items[index].requests = 0
            items[index].inFinalTranscript = false
        }
        for request in log.sent {
            for id in Set(request.items) { items[id].requests += 1 }
        }
        let mainSource = finalRequest.flatMap { sent[$0].querySource }
        if let last = log.sent.indices.last(where: { log.sent[$0].querySource == mainSource }) ?? log.sent.indices.last {
            var seen = Set<Int>()
            log.finalRequest = last
            log.finalTranscript = log.sent[last].items.filter { seen.insert($0).inserted }
            for id in log.finalTranscript { items[id].inFinalTranscript = true }
        }
        log.items = items
        return log
    }
}

/// Text and labels shared by both providers' readers.
enum ProviderContextText {
    static let previewLength = 200

    static func toolLabel(name: String, namespace: String? = nil) -> (label: String, server: String?) {
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? ""
            let tool = parts.dropFirst().joined(separator: "__")
            return (tool.isEmpty ? server : "\(server)/\(tool)", server)
        }
        if let namespace, namespace.hasPrefix("mcp__") {
            let server = namespace.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            return ("\(server)/\(name)", server)
        }
        return (name, nil)
    }

    /// The first line of injected text, so a reminder reads by what it says.
    static func reminderLabel(_ text: String) -> String {
        let line = text
            .replacingOccurrences(of: "<system-reminder>", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Injected text"
        return line.count > 70 ? String(line.prefix(69)) + "…" : line
    }

    static func preview(_ text: String) -> String {
        let flat = text.prefix(previewLength * 2).split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > previewLength ? String(flat.prefix(previewLength - 1)) + "…" : flat
    }

    static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return (value as? String) ?? String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The text a person reads for one block or item of either provider.
    static func display(_ value: Any, kind: ProviderContextKind) -> String {
        if kind == .toolDefinition { return prettyJSON(value) }
        if let string = value as? String { return string }
        // An OpenCode tool result is its list of content parts.
        if kind == .toolResult, let parts = value as? [Any] { return content(parts) }
        guard let block = value as? [String: Any] else { return prettyJSON(value) }
        switch block["type"] as? String {
        case "text", "input_text", "output_text":
            return block["text"] as? String ?? ""
        case "thinking":
            return block["thinking"] as? String ?? ""
        case "redacted_thinking":
            return "[redacted thinking: \((block["data"] as? String)?.count ?? 0) characters]"
        case "tool_use", "server_tool_use":
            return prettyJSON(block["input"] ?? [String: Any]())
        case "tool_result", "web_search_tool_result":
            return content(block["content"])
        case "image", "input_image":
            return "[image]"
        case "document":
            return "[document]"
        case "message", "agent_message":
            return content(block["content"])
        case "reasoning":
            let summary = (block["summary"] as? [Any] ?? []).map { content([$0]) }.filter { !$0.isEmpty }
            if !summary.isEmpty { return summary.joined(separator: "\n") }
            return "[encrypted reasoning: \((block["encrypted_content"] as? String)?.count ?? 0) characters]"
        case "function_call":
            let arguments = block["arguments"] as? String ?? ""
            if let data = arguments.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return prettyJSON(object)
            }
            return arguments
        case "custom_tool_call":
            return block["input"] as? String ?? ""
        case "local_shell_call":
            return prettyJSON(block["action"] ?? [String: Any]())
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            return content(block["output"])
        default:
            if let text = block["text"] as? String { return text }
            return prettyJSON(block)
        }
    }

    private static func content(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let parts = value as? [Any] {
            return parts.map { part -> String in
                guard let item = part as? [String: Any] else { return (part as? String) ?? "" }
                switch item["type"] as? String {
                case "text", "input_text", "output_text", "summary_text": return item["text"] as? String ?? ""
                case "image", "input_image": return "[image]"
                case "encrypted_content": return "[encrypted content: \((item["encrypted_content"] as? String)?.count ?? 0) characters]"
                default: return prettyJSON(item)
                }
            }.joined(separator: "\n")
        }
        if let item = value as? [String: Any] {
            if let nested = item["content"] { return content(nested) }
            return prettyJSON(item)
        }
        return ""
    }

    /// How much of a measured token delta an item takes. An image counts as a
    /// typical image's tokens rather than its base64 length.
    static func weight(text: String, kind: ProviderContextKind) -> Int {
        kind == .image ? 6_400 : max(1, text.unicodeScalars.count)
    }
}

/// Builds items one at a time while a reader parses a file.
private struct ProviderItemBuilder {
    var items: [ProviderContextItem] = []

    mutating func add(
        _ value: Any, kind: ProviderContextKind, role: String, label: String, server: String? = nil,
        location: ProviderContextLocation, callID: String? = nil
    ) -> Int {
        let text = ProviderContextText.display(value, kind: kind)
        var hasher = Hasher()
        // Every image displays as "[image]"; its data tells two images apart.
        hasher.combine(kind == .image ? ProviderContextText.prettyJSON(value) : text)
        let id = items.count
        items.append(ProviderContextItem(
            id: id, kind: kind, role: role, label: label, server: server,
            weight: ProviderContextText.weight(text: text, kind: kind),
            textLength: text.unicodeScalars.count,
            preview: ProviderContextText.preview(text),
            contentKey: hasher.finalize(),
            location: location, callID: callID
        ))
        return id
    }
}

/// Parses one provider log line by line; `finish` can run after any line, so a
/// growing file is read again only from where it stopped.
protocol ProviderRequestLogParser: AnyObject {
    func consume(_ object: [String: Any], offset: UInt64, length: Int)
    func finish(file: URL) -> ProviderAgentLog
}

/// Splits measured context tokens across the items each request was sent.

/// JSON as JavaScript's `JSON.stringify` writes it with keys sorted, which is
/// what Claude Code hashes to name a message.
enum ProviderCanonicalJSON {
    static func sha256(_ value: Any) -> String {
        var output = ""
        write(value, to: &output)
        return SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ value: Any, to output: inout String) {
        switch value {
        case let string as String:
            writeString(string, to: &output)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output += number.boolValue ? "true" : "false"
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                output += double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : "\(double)"
            } else {
                output += number.stringValue
            }
        case let array as [Any]:
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                write(element, to: &output)
            }
            output += "]"
        case let object as [String: Any]:
            output += "{"
            // JavaScript sorts keys by UTF-16 code units.
            for (index, key) in object.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }).enumerated() {
                if index > 0 { output += "," }
                writeString(key, to: &output)
                output += ":"
                write(object[key] ?? NSNull(), to: &output)
            }
            output += "}"
        default:
            output += "null"
        }
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

final class ClaudeRequestLogParser: ProviderRequestLogParser {
    private struct Request {
        let id: String
        let base: String?
        let keep: Int
        let tail: [String]
        let shapeHash: String?
        let timestamp: String?
        let querySource: String?
        let line: ProviderContextLocation
    }

    /// A content block of a transcript line, kept until its message is complete.
    private struct PendingBlock {
        let value: Any
        let location: ProviderContextLocation
    }

    private var builder = ProviderItemBuilder()
    private var shapes: [String: [Int]] = [:]
    private var blobs: [String: [Int]] = [:]
    private var requests: [Request] = []
    private var usageByRequest: [String: ConversationTokenUsage] = [:]
    /// A block read from two messages' lines (one line alone, then merged) stays one item.
    private var itemsByLocation: [String: Int] = [:]
    private var assistantGroup: (id: String, blocks: [PendingBlock])?
    private var userRun: [[PendingBlock]] = []

    func consume(_ object: [String: Any], offset: UInt64, length: Int) {
        switch object["type"] as? String {
        case "api-request-shape":
            guard let hash = object["shapeHash"] as? String, shapes[hash] == nil,
                  let shape = object["shape"] as? [String: Any] else { return }
            var ids: [Int] = []
            for (index, part) in (shape["system"] as? [Any] ?? []).enumerated() {
                ids.append(builder.add(
                    part, kind: .systemPrompt, role: "system", label: "System prompt (part \(index + 1))",
                    location: .init(offset: offset, length: length, path: [.key("shape"), .key("system"), .index(index)])
                ))
            }
            for (index, tool) in (shape["tools"] as? [Any] ?? []).enumerated() {
                let name = (tool as? [String: Any])?["name"] as? String ?? "tool \(index + 1)"
                let named = ProviderContextText.toolLabel(name: name)
                ids.append(builder.add(
                    tool, kind: .toolDefinition, role: "system", label: named.label, server: named.server,
                    location: .init(offset: offset, length: length, path: [.key("shape"), .key("tools"), .index(index)])
                ))
            }
            shapes[hash] = ids
        case "api-request-blob":
            guard let hash = object["hash"] as? String, blobs[hash] == nil,
                  let message = object["message"] as? [String: Any] else { return }
            let role = message["role"] as? String ?? "user"
            let contentPath: [ProviderJSONPathComponent] = [.key("message"), .key("content")]
            if let text = message["content"] as? String {
                blobs[hash] = [addBlock(text, role: role, location: .init(offset: offset, length: length, path: contentPath))]
            } else {
                blobs[hash] = (message["content"] as? [Any] ?? []).enumerated().map { index, block in
                    addBlock(block, role: role, location: .init(offset: offset, length: length, path: contentPath + [.index(index)]))
                }
            }
        case "api-request":
            guard let id = object["id"] as? String else { return }
            requests.append(Request(
                id: id,
                base: object["base"] as? String,
                keep: object["keep"] as? Int ?? 0,
                tail: object["tail"] as? [String] ?? [],
                shapeHash: object["shapeHash"] as? String,
                timestamp: object["timestamp"] as? String,
                querySource: object["querySource"] as? String,
                line: .init(offset: offset, length: length, path: [])
            ))
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return }
            closeUserRun()
            let blocks = transcriptBlocks(message, offset: offset, length: length)
            let id = message["id"] as? String ?? "line:\(offset)"
            if assistantGroup?.id == id {
                assistantGroup?.blocks += blocks
            } else {
                closeAssistantGroup()
                assistantGroup = (id, blocks)
            }
            guard let reference = object["requestRef"] as? String,
                  let payload = message["usage"] as? [String: Any] else { return }
            let usage = ConversationTokenUsage(providerPayload: payload)
            // A call is written once per content block; the last line's usage wins.
            if !usage.isEmpty { usageByRequest[reference] = usage }
        case "user":
            guard let message = object["message"] as? [String: Any] else { return }
            closeAssistantGroup()
            let blocks = transcriptBlocks(message, offset: offset, length: length)
            register(["role": "user", "content": message["content"] ?? ""], blocks: blocks, role: "user")
            userRun.append(blocks)
        default:
            return
        }
    }

    /// One line's content blocks; plain string content is one text block.
    private func transcriptBlocks(_ message: [String: Any], offset: UInt64, length: Int) -> [PendingBlock] {
        let path: [ProviderJSONPathComponent] = [.key("message"), .key("content")]
        if let text = message["content"] as? String {
            return [PendingBlock(value: text, location: .init(offset: offset, length: length, path: path))]
        }
        return (message["content"] as? [Any] ?? []).enumerated().map { index, block in
            PendingBlock(value: block, location: .init(offset: offset, length: length, path: path + [.index(index)]))
        }
    }

    private func closeAssistantGroup() {
        guard let group = assistantGroup else { return }
        assistantGroup = nil
        register(["role": "assistant", "content": group.blocks.map(\.value)], blocks: group.blocks, role: "assistant")
    }

    /// Consecutive user lines go to the API as one message.
    private func closeUserRun() {
        defer { userRun = [] }
        guard userRun.count > 1 else { return }
        let blocks = userRun.flatMap { $0 }
        let content = blocks.map { block -> Any in
            (block.value as? String).map { ["type": "text", "text": $0] as [String: Any] } ?? block.value
        }
        register(["role": "user", "content": content], blocks: blocks, role: "user")
    }

    private func register(_ message: [String: Any], blocks: [PendingBlock], role: String) {
        let hash = ProviderCanonicalJSON.sha256(message)
        guard blobs[hash] == nil else { return }
        blobs[hash] = blocks.map { block in
            let key = "\(block.location.offset):\(block.location.path.count):\(block.location.path.last.map { "\($0)" } ?? "")"
            if let existing = itemsByLocation[key] { return existing }
            let id = addBlock(block.value, role: role, location: block.location)
            itemsByLocation[key] = id
            return id
        }
    }

    private func addBlock(_ block: Any, role: String, location: ProviderContextLocation) -> Int {
        let object = block as? [String: Any]
        let type = object?["type"] as? String ?? "text"
        switch (role, type) {
        case ("assistant", "text"):
            return builder.add(block, kind: .assistantText, role: role, label: "Assistant text", location: location)
        case ("assistant", "thinking"), ("assistant", "redacted_thinking"):
            return builder.add(block, kind: .thinking, role: role, label: "Thinking", location: location)
        case ("assistant", "tool_use"), ("assistant", "server_tool_use"):
            let named = ProviderContextText.toolLabel(name: object?["name"] as? String ?? "Tool")
            return builder.add(block, kind: .toolCall, role: role, label: named.label, server: named.server,
                               location: location, callID: object?["id"] as? String)
        case (_, "tool_result"):
            return builder.add(block, kind: .toolResult, role: role, label: "Tool result",
                               location: location, callID: object?["tool_use_id"] as? String)
        case (_, "image"):
            return builder.add(block, kind: .image, role: role, label: "Image", location: location)
        case (_, "text"):
            let text = ProviderContextText.display(block, kind: .userText)
            if role == "system" || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<system-reminder>") {
                return builder.add(block, kind: .systemReminder, role: role, label: ProviderContextText.reminderLabel(text), location: location)
            }
            return builder.add(block, kind: .userText, role: role, label: "User message", location: location)
        default:
            return builder.add(block, kind: .other, role: role, label: type, location: location)
        }
    }

    func finish(file: URL) -> ProviderAgentLog {
        var log = ProviderAgentLog(provider: .claude, file: file)
        // The last message may still be growing: register what it holds so far
        // without closing it, so lines appended later extend the same message.
        if let group = assistantGroup {
            register(["role": "assistant", "content": group.blocks.map(\.value)], blocks: group.blocks, role: "assistant")
        }
        if userRun.count > 1 {
            let run = userRun
            closeUserRun()
            userRun = run
        }
        guard !requests.isEmpty else { return log }
        var items = builder.items
        linkToolResults(&items)

        var indexByID: [String: Int] = [:]
        var chains: [[String]] = []
        var compacted = Set<Int>()
        for (index, request) in requests.enumerated() {
            var chain: [String] = []
            if let base = request.base, let baseIndex = indexByID[base] {
                chain = Array(chains[baseIndex].prefix(request.keep))
                if request.keep < chains[baseIndex].count {
                    log.compactions += 1
                    compacted.insert(index)
                }
            }
            chain += request.tail
            chains.append(chain)
            indexByID[request.id] = index
        }

        var sent: [(items: [Int], context: Int?)] = []
        log.sentRequests = requests.count
        for (index, request) in requests.enumerated() {
            let shape = request.shapeHash.flatMap { shapes[$0] }
            let shapeItems = shape ?? []
            var messageItems: [Int] = []
            var messageLengths: [Int] = []
            var missing = 0
            for hash in chains[index] {
                guard let blob = blobs[hash] else {
                    missing += 1
                    continue
                }
                messageItems += blob
                messageLengths.append(blob.count)
            }
            let ids = shapeItems + messageItems
            for id in Set(ids) { items[id].requests += 1 }
            let usage = usageByRequest[request.id].map {
                ProviderRequestUsage(
                    timestamp: request.timestamp,
                    contextTokens: $0.inputTokens + $0.cacheReadTokens + $0.cacheCreationTokens,
                    cacheReadTokens: $0.cacheReadTokens,
                    cacheWriteTokens: $0.cacheCreationTokens,
                    outputTokens: $0.outputTokens
                )
            }
            sent.append((ids, usage?.contextTokens))
            if let usage { log.requests.append(usage) }
            log.sent.append(ProviderSentRequest(
                timestamp: request.timestamp, querySource: request.querySource, items: ids,
                messageLengths: messageLengths, missingMessages: missing, missingShape: request.shapeHash != nil && shape == nil,
                usage: usage, line: request.line, compacted: compacted.contains(index)
            ))
        }
        ProviderTokenCalibration.apply(items: &items, requests: sent)

        // Side queries (titles, summaries) have their own source; the
        // conversation is the source most requests share.
        let sources = Dictionary(grouping: requests.map { $0.querySource ?? "" }, by: { $0 }).mapValues(\.count)
        let mainSource = sources.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        if let last = requests.indices.last(where: { (requests[$0].querySource ?? "") == mainSource }) {
            var seen = Set<Int>()
            log.finalRequest = last
            log.finalTranscript = sent[last].items.filter { seen.insert($0).inserted }
            for id in log.finalTranscript { items[id].inFinalTranscript = true }
        }
        log.items = items
        return log
    }

    private func linkToolResults(_ items: inout [ProviderContextItem]) {
        var calls: [String: Int] = [:]
        for item in items where item.kind == .toolCall {
            if let callID = item.callID { calls[callID] = item.id }
        }
        for index in items.indices where items[index].kind == .toolResult {
            guard let callID = items[index].callID, let call = calls[callID] else { continue }
            items[index].label = items[call].label
            items[index].server = items[call].server
            items[index].callItemID = call
        }
    }
}

final class CodexRolloutParser: ProviderRequestLogParser {
    private struct Record {
        let epoch: Int
        let boundary: Int
        let timestamp: String?
        let input: Int
        let cached: Int
        let output: Int
    }

    private static let outputTypes: Set<String> = [
        "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call",
        "tool_search_call", "image_generation_call",
    ]

    private var builder = ProviderItemBuilder()
    private var instructions: [Int] = []
    private var epochs: [[Int]] = [[]]
    /// Where the trailing run of model output starts in the current epoch: the
    /// request that produced it was sent only what came before.
    private var outputStart: Int?
    private var usageRecords: [Record] = []
    private var countRecords: [Record] = []
    private var lastCountTotal: Int?
    private var compactions = 0

    func consume(_ object: [String: Any], offset: UInt64, length: Int) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = object["timestamp"] as? String
        switch object["type"] as? String {
        case "session_meta":
            guard instructions.isEmpty, let base = payload["base_instructions"] else { return }
            let isTextObject = (base as? [String: Any])?["text"] is String
            let value = isTextObject ? (base as? [String: Any])?["text"] ?? base : base
            let path: [ProviderJSONPathComponent] = [.key("payload"), .key("base_instructions")] + (isTextObject ? [.key("text")] : [])
            instructions = [builder.add(
                value, kind: .systemPrompt, role: "system", label: "Codex base instructions",
                location: .init(offset: offset, length: length, path: path)
            )]
        case "response_item":
            let id = addItem(payload, location: .init(offset: offset, length: length, path: [.key("payload")]))
            append(id, isOutput: Self.isOutput(payload))
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any] else { return }
            usageRecords.append(record(usage, timestamp: timestamp))
            outputStart = nil
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            // Older rollouts only carry these, repeated whenever usage is re-announced.
            let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int
            guard total == nil || total != lastCountTotal else { return }
            lastCountTotal = total
            countRecords.append(record(last, timestamp: timestamp))
        case "compacted":
            compactions += 1
            outputStart = nil
            if let history = payload["replacement_history"] as? [Any] {
                epochs.append(history.enumerated().map { index, item in
                    addItem(item, location: .init(offset: offset, length: length, path: [.key("payload"), .key("replacement_history"), .index(index)]))
                })
            } else {
                epochs.append([builder.add(
                    payload["message"] ?? "", kind: .userText, role: "user", label: "Compaction summary",
                    location: .init(offset: offset, length: length, path: [.key("payload"), .key("message")])
                )])
            }
        default:
            return
        }
    }

    private func record(_ usage: [String: Any], timestamp: String?) -> Record {
        Record(
            epoch: epochs.count - 1,
            boundary: outputStart ?? epochs[epochs.count - 1].count,
            timestamp: timestamp,
            input: usage["input_tokens"] as? Int ?? 0,
            cached: usage["cached_input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0
        )
    }

    private func append(_ id: Int, isOutput: Bool) {
        epochs[epochs.count - 1].append(id)
        if isOutput {
            if outputStart == nil { outputStart = epochs[epochs.count - 1].count - 1 }
        } else {
            outputStart = nil
        }
    }

    private static func isOutput(_ payload: [String: Any]) -> Bool {
        let type = payload["type"] as? String ?? ""
        return outputTypes.contains(type) || (type == "message" && payload["role"] as? String == "assistant")
    }

    private func addItem(_ value: Any, location: ProviderContextLocation) -> Int {
        let payload = value as? [String: Any] ?? [:]
        let type = payload["type"] as? String ?? "other"
        switch type {
        case "message":
            let role = payload["role"] as? String ?? "user"
            if role == "assistant" {
                return builder.add(value, kind: .assistantText, role: role, label: "Assistant text", location: location)
            }
            let text = ProviderContextText.display(value, kind: .userText).trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "developer" || role == "system" || text.hasPrefix("<") || text.hasPrefix("#") {
                return builder.add(value, kind: .systemReminder, role: role, label: ProviderContextText.reminderLabel(text), location: location)
            }
            return builder.add(value, kind: .userText, role: role, label: "User message", location: location)
        case "reasoning":
            return builder.add(value, kind: .thinking, role: "assistant", label: "Reasoning", location: location)
        case "function_call", "custom_tool_call", "local_shell_call", "web_search_call", "tool_search_call":
            let named = ProviderContextText.toolLabel(
                name: payload["name"] as? String ?? (type == "local_shell_call" ? "shell" : type),
                namespace: payload["namespace"] as? String
            )
            return builder.add(value, kind: .toolCall, role: "assistant", label: named.label, server: named.server,
                               location: location, callID: payload["call_id"] as? String)
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output", "tool_search_output":
            return builder.add(value, kind: .toolResult, role: "tool", label: "Tool result",
                               location: location, callID: payload["call_id"] as? String)
        case "compaction":
            return builder.add(value, kind: .other, role: "system", label: "Compaction summary", location: location)
        case "agent_message":
            let author = payload["author"] as? String
            return builder.add(value, kind: .other, role: "agent", label: author.map { "Message from \($0)" } ?? "Agent message", location: location)
        default:
            return builder.add(value, kind: .other, role: payload["role"] as? String ?? "other", label: type, location: location)
        }
    }

    func finish(file: URL) -> ProviderAgentLog {
        var log = ProviderAgentLog(provider: .codex, file: file)
        let records = usageRecords.isEmpty ? countRecords : usageRecords
        guard !records.isEmpty else { return log }
        var items = builder.items
        var calls: [String: Int] = [:]
        for item in items where item.kind == .toolCall {
            if let callID = item.callID { calls[callID] = item.id }
        }
        for index in items.indices where items[index].kind == .toolResult {
            guard let callID = items[index].callID, let call = calls[callID] else { continue }
            items[index].label = items[call].label
            items[index].server = items[call].server
            items[index].callItemID = call
        }

        // Tool definitions are never saved: whatever the first request cost
        // beyond its visible items, measured with the append ratio, is theirs.
        let hidden = items.count
        items.append(ProviderContextItem(
            id: hidden, kind: .hiddenOverhead, role: "system",
            label: "Tool definitions and other context Codex does not save",
            weight: 0, textLength: 0, preview: "Codex sends this with every request but does not write it to its session file.",
            contentKey: 0, location: nil, callID: nil
        ))
        var deltas: [(items: [Int], tokens: Int)] = []
        for (previous, next) in zip(records, records.dropFirst()) where previous.epoch == next.epoch && next.boundary >= previous.boundary {
            deltas.append((Array(epochs[next.epoch][previous.boundary..<next.boundary]), next.input - previous.input))
        }
        let first = records[0]
        let hiddenTokens = ProviderTokenCalibration.hiddenTokens(
            items: items, firstVisible: instructions + epochs[first.epoch][0..<first.boundary], firstContext: first.input, deltas: deltas
        )

        let sent = records.map { record -> (items: [Int], context: Int?) in
            ([hidden] + instructions + epochs[record.epoch][0..<record.boundary], record.input)
        }
        for request in sent {
            for id in Set(request.items) { items[id].requests += 1 }
        }
        ProviderTokenCalibration.apply(items: &items, requests: sent, preassigned: [hidden: hiddenTokens])
        log.requests = records.map {
            ProviderRequestUsage(
                timestamp: $0.timestamp, contextTokens: $0.input, cacheReadTokens: $0.cached, cacheWriteTokens: nil, outputTokens: $0.output
            )
        }
        log.sent = zip(records.indices, sent).map { index, request in
            ProviderSentRequest(
                timestamp: log.requests[index].timestamp, querySource: nil, items: request.items,
                messageLengths: [], missingMessages: 0, missingShape: false, usage: log.requests[index], line: nil,
                compacted: index > 0 && records[index].epoch != records[index - 1].epoch
            )
        }
        log.finalTranscript = sent[sent.count - 1].items
        log.finalRequest = sent.count - 1
        for id in log.finalTranscript { items[id].inFinalTranscript = true }
        log.sentRequests = records.count
        log.compactions = compactions
        log.items = items
        return log
    }
}

final class OpenCodeMessageLogParser: ProviderRequestLogParser {
    private struct Record {
        let epoch: Int
        /// The request was sent the epoch's items before this one.
        let boundary: Int
        let timestamp: String?
        let context: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
    }

    private var builder = ProviderItemBuilder()
    private var epochs: [[Int]] = [[]]
    private var records: [Record] = []
    private var compactions = 0

    func consume(_ object: [String: Any], offset: UInt64, length: Int) {
        func at(_ path: [ProviderJSONPathComponent]) -> ProviderContextLocation { .init(offset: offset, length: length, path: path) }
        let timestamp = ((object["time"] as? [String: Any])?["created"] as? NSNumber).map {
            Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date(timeIntervalSince1970: $0.doubleValue / 1_000))
        }
        switch object["type"] as? String {
        case "user":
            append(builder.add(object["text"] ?? "", kind: .userText, role: "user", label: "User message", location: at([.key("text")])))
            for (index, file) in (object["files"] as? [[String: Any]] ?? []).enumerated() {
                let isImage = (file["mime"] as? String ?? file["uri"] as? String ?? "").contains("image")
                append(builder.add(
                    isImage ? ["type": "image", "source": file] : file, kind: isImage ? .image : .other, role: "user",
                    label: isImage ? "Image" : file["name"] as? String ?? "Attached file", location: at([.key("files"), .index(index)])
                ))
            }
        case "synthetic", "system":
            let text = object["text"] as? String ?? ""
            append(builder.add(text, kind: .systemReminder, role: "user", label: ProviderContextText.reminderLabel(text), location: at([.key("text")])))
        case "skill":
            append(builder.add(object["text"] ?? "", kind: .systemReminder, role: "user",
                               label: "Skill \(object["name"] as? String ?? "")", location: at([.key("text")])))
        case "shell":
            append(builder.add(object["output"] ?? object["command"] ?? "", kind: .toolResult, role: "user",
                               label: "shell", location: at([.key("output")])))
        case "assistant":
            let boundary = epochs[epochs.count - 1].count
            for (index, part) in (object["content"] as? [[String: Any]] ?? []).enumerated() {
                let path: [ProviderJSONPathComponent] = [.key("content"), .index(index)]
                switch part["type"] as? String {
                case "text":
                    append(builder.add(part["text"] ?? "", kind: .assistantText, role: "assistant", label: "Assistant text", location: at(path + [.key("text")])))
                case "reasoning":
                    append(builder.add(part["text"] ?? "", kind: .thinking, role: "assistant", label: "Reasoning", location: at(path + [.key("text")])))
                case "tool":
                    let state = part["state"] as? [String: Any] ?? [:]
                    let named = ProviderContextText.toolLabel(name: part["name"] as? String ?? "tool")
                    let callID = part["id"] as? String
                    append(builder.add(state["input"] ?? [String: Any](), kind: .toolCall, role: "assistant", label: named.label, server: named.server,
                                       location: at(path + [.key("state"), .key("input")]), callID: callID))
                    if let content = state["content"] {
                        append(builder.add(content, kind: .toolResult, role: "tool", label: named.label, server: named.server,
                                           location: at(path + [.key("state"), .key("content")]), callID: callID))
                    } else if let error = state["error"] {
                        let message = (error as? [String: Any])?["message"]
                        append(builder.add(message ?? error, kind: .toolResult, role: "tool", label: named.label, server: named.server,
                                           location: at(path + [.key("state"), .key("error")] + (message == nil ? [] : [.key("message")])), callID: callID))
                    }
                default:
                    continue
                }
            }
            let tokens = object["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            func value(_ object: [String: Any], _ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
            let cacheRead = value(cache, "read"), cacheWrite = value(cache, "write")
            let context = value(tokens, "input") + cacheRead + cacheWrite
            // A request that was cut off before OpenCode billed it reports nothing to place.
            guard context > 0 else { return }
            records.append(Record(
                epoch: epochs.count - 1, boundary: boundary, timestamp: timestamp, context: context,
                cacheRead: cacheRead, cacheWrite: cacheWrite, output: value(tokens, "output") + value(tokens, "reasoning")
            ))
        case "compaction":
            guard (object["status"] as? String ?? "completed") == "completed" else { return }
            compactions += 1
            epochs.append([builder.add(object["summary"] ?? "", kind: .userText, role: "user", label: "Compaction summary", location: at([.key("summary")]))])
        default:
            return
        }
    }

    private func append(_ id: Int) {
        epochs[epochs.count - 1].append(id)
    }

    func finish(file: URL) -> ProviderAgentLog {
        var log = ProviderAgentLog(provider: .opencode, file: file)
        guard !records.isEmpty else { return log }
        var items = builder.items
        var calls: [String: Int] = [:]
        for item in items where item.kind == .toolCall {
            if let callID = item.callID { calls[callID] = item.id }
        }
        for index in items.indices where items[index].kind == .toolResult {
            if let callID = items[index].callID { items[index].callItemID = calls[callID] }
        }
        let hidden = items.count
        items.append(ProviderContextItem(
            id: hidden, kind: .hiddenOverhead, role: "system",
            label: "System prompt, tool definitions and other context OpenCode does not return",
            weight: 0, textLength: 0, preview: "OpenCode sends this with every request but its server does not list it with the session's messages.",
            contentKey: 0, location: nil, callID: nil
        ))
        var deltas: [(items: [Int], tokens: Int)] = []
        for (previous, next) in zip(records, records.dropFirst()) where previous.epoch == next.epoch && next.boundary >= previous.boundary {
            deltas.append((Array(epochs[next.epoch][previous.boundary..<next.boundary]), next.context - previous.context))
        }
        let first = records[0]
        let hiddenTokens = ProviderTokenCalibration.hiddenTokens(
            items: items, firstVisible: Array(epochs[first.epoch][0..<first.boundary]), firstContext: first.context, deltas: deltas
        )
        let sent = records.map { record -> (items: [Int], context: Int?) in
            ([hidden] + epochs[record.epoch][0..<record.boundary], record.context)
        }
        for request in sent {
            for id in Set(request.items) { items[id].requests += 1 }
        }
        ProviderTokenCalibration.apply(items: &items, requests: sent, preassigned: [hidden: hiddenTokens])
        log.requests = records.map {
            ProviderRequestUsage(
                timestamp: $0.timestamp, contextTokens: $0.context, cacheReadTokens: $0.cacheRead, cacheWriteTokens: $0.cacheWrite, outputTokens: $0.output
            )
        }
        log.sent = zip(records.indices, sent).map { index, request in
            ProviderSentRequest(
                timestamp: log.requests[index].timestamp, querySource: nil, items: request.items,
                messageLengths: [], missingMessages: 0, missingShape: false, usage: log.requests[index], line: nil,
                compacted: index > 0 && records[index].epoch != records[index - 1].epoch
            )
        }
        log.finalTranscript = sent[sent.count - 1].items
        log.finalRequest = sent.count - 1
        for id in log.finalTranscript { items[id].inFinalTranscript = true }
        log.sentRequests = records.count
        log.compactions = compactions
        log.items = items
        return log
    }
}

/// Parsed logs kept per file and extended as the file grows, so polling the
/// token map does not re-read a long session from the start.
final class ProviderRequestLogStore: @unchecked Sendable {
    static let shared = ProviderRequestLogStore()

    /// One file's parse. Its own lock serializes reading that file, so a long
    /// parse never blocks the store or another file's readers.
    private final class Entry {
        let parser: ProviderRequestLogParser
        let fileNumber: Int
        let lock = NSLock()
        var parsedOffset: UInt64 = 0
        var log: ProviderAgentLog?
        var lastUsed = Date()
        init(parser: ProviderRequestLogParser, fileNumber: Int) {
            self.parser = parser
            self.fileNumber = fileNumber
        }
    }

    /// Parsed files kept at once; the least recently used is dropped first.
    private static let entryLimit = 12

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var codexFiles: [String: URL] = [:]
    /// The last few texts read, so paging through one item does not re-parse its line per chunk.
    private var recentTexts: [(key: String, text: String)] = []

    func log(provider: ConversationProvider, file: URL) -> ProviderAgentLog? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        let current = entry(for: file, provider: provider, fileNumber: fileNumber, size: size)
        current.lock.lock()
        defer { current.lock.unlock() }
        if current.log == nil || size > current.parsedOffset {
            current.parsedOffset = Self.readLines(of: file, from: current.parsedOffset) { line, offset in
                // Each line's objects are released as soon as it is read, not at the end of a long file.
                autoreleasepool {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    current.parser.consume(object, offset: offset, length: line.count)
                }
            }
            current.log = current.parser.finish(file: file)
            current.log?.fileNumber = fileNumber
        }
        return current.log
    }

    /// The file's entry, started again when the file was replaced or shrank.
    private func entry(for file: URL, provider: ConversationProvider, fileNumber: Int, size: UInt64) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[file.path], existing.fileNumber == fileNumber, size >= existing.parsedOffset {
            existing.lastUsed = Date()
            return existing
        }
        let parser: ProviderRequestLogParser = switch provider {
        case .claude: ClaudeRequestLogParser()
        case .codex: CodexRolloutParser()
        case .opencode: OpenCodeMessageLogParser()
        }
        let created = Entry(parser: parser, fileNumber: fileNumber)
        entries[file.path] = created
        while entries.count > Self.entryLimit, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
        return created
    }

    /// Full texts of several items, each line read and parsed once however many items it holds.
    func texts(of items: [ProviderContextItem], in log: ProviderAgentLog) -> [Int: String] {
        var result: [Int: String] = [:]
        let kinds = Dictionary(items.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        readValues(of: items.compactMap { item in item.location.map { (item.id, $0) } }, in: log) { id, value in
            result[id] = ProviderContextText.display(value, kind: kinds[id] ?? .other)
        }
        for item in items where item.location == nil { result[item.id] = item.preview }
        return result
    }

    /// The JSON values at several locations of the log, each line read and parsed once.
    func values(at locations: [(key: Int, location: ProviderContextLocation)], in log: ProviderAgentLog) -> [Int: Any] {
        var result: [Int: Any] = [:]
        readValues(of: locations.map { ($0.key, $0.location) }, in: log) { result[$0] = $1 }
        return result
    }

    /// The log's file, unless it was replaced since the log was parsed.
    private static func open(_ log: ProviderAgentLog) -> FileHandle? {
        guard let handle = try? FileHandle(forReadingFrom: log.file) else { return nil }
        var info = stat()
        if let expected = log.fileNumber, fstat(handle.fileDescriptor, &info) != 0 || Int(info.st_ino) != expected {
            try? handle.close()
            return nil
        }
        return handle
    }

    private func readValues(of locations: [(Int, ProviderContextLocation)], in log: ProviderAgentLog, _ body: (Int, Any) -> Void) {
        guard let handle = Self.open(log) else { return }
        defer { try? handle.close() }
        for (offset, lineLocations) in Dictionary(grouping: locations, by: { $0.1.offset }) {
            autoreleasepool {
                guard let length = lineLocations.first?.1.length,
                      (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.read(upToCount: length),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return }
                for (key, location) in lineLocations { body(key, Self.value(at: location.path, in: object)) }
            }
        }
    }

    private static func value(at path: [ProviderJSONPathComponent], in object: Any) -> Any {
        var value = object
        for component in path {
            switch component {
            case .key(let name): value = (value as? [String: Any])?[name] ?? NSNull()
            case .index(let index):
                let array = value as? [Any] ?? []
                value = array.indices.contains(index) ? array[index] : NSNull()
            }
        }
        return value
    }

    /// The full text of one item, read back from its line in the file.
    func text(of item: ProviderContextItem, in log: ProviderAgentLog) -> String {
        guard let location = item.location else { return item.preview }
        // A replaced file (OpenCode's) numbers its items afresh, so its texts are cached apart.
        let key = "\(log.file.path)#\(log.fileNumber ?? 0)#\(item.id)"
        lock.lock()
        if let recent = recentTexts.first(where: { $0.key == key }) {
            lock.unlock()
            return recent.text
        }
        lock.unlock()
        var text = item.preview
        if let handle = Self.open(log) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: location.offset)
            if let data = try? handle.read(upToCount: location.length),
               let object = try? JSONSerialization.jsonObject(with: data) {
                text = ProviderContextText.display(Self.value(at: location.path, in: object), kind: item.kind)
            }
        }
        lock.lock()
        recentTexts.append((key, text))
        if recentTexts.count > 4 { recentTexts.removeFirst() }
        lock.unlock()
        return text
    }

    /// Codex names a rollout file after its thread, under a dated directory.
    func codexRolloutFile(threadID: String, codexHome: String) -> URL? {
        lock.lock()
        if let known = codexFiles[threadID], FileManager.default.fileExists(atPath: known.path) {
            lock.unlock()
            return known
        }
        lock.unlock()
        let home = URL(fileURLWithPath: codexHome, isDirectory: true)
        let suffix = "-\(threadID).jsonl"
        for root in ["sessions", "archived_sessions"] {
            guard let files = FileManager.default.enumerator(
                at: home.appendingPathComponent(root, isDirectory: true), includingPropertiesForKeys: nil
            ) else { continue }
            for case let file as URL in files where file.lastPathComponent.hasPrefix("rollout-") && file.lastPathComponent.hasSuffix(suffix) {
                lock.lock()
                codexFiles[threadID] = file
                lock.unlock()
                return file
            }
        }
        return nil
    }

    /// Calls `body` with each complete line from `start` and its byte offset;
    /// returns the offset after the last complete line, where the next read resumes.
    private static func readLines(of file: URL, from start: UInt64, _ body: (Data, UInt64) -> Void) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return start }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil else { return start }
        var lineStart = start
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var searchFrom = buffer.startIndex
            while let newline = buffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[searchFrom..<newline]
                if !line.isEmpty { body(Data(line), lineStart) }
                lineStart += UInt64(line.count + 1)
                searchFrom = buffer.index(after: newline)
            }
            buffer = Data(buffer[searchFrom...])
        }
        return lineStart
    }
}

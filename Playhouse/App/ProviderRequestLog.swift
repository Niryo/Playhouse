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
    let contextTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
}

/// Everything one agent (a session's main agent or one subagent) was sent.
struct ProviderAgentLog: Sendable {
    let provider: ConversationProvider
    let file: URL
    var items: [ProviderContextItem] = []
    var requests: [ProviderRequestUsage] = []
    /// Item IDs of the last request's context, in the order they were sent.
    var finalTranscript: [Int] = []
    /// Model requests the log records, measured or not.
    var sentRequests = 0
    var compactions = 0

    var isAvailable: Bool { !requests.isEmpty }
    var sentTokens: Int { requests.reduce(0) { $0 + $1.contextTokens } }
    var finalTranscriptTokens: Int { finalTranscript.reduce(0) { $0 + items[$1].tokens } }
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
        hasher.combine(text)
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
private enum ProviderTokenCalibration {
    /// Walks the requests in order. A request's context minus the items already
    /// measured is what its new items cost, shared by weight. Items no request
    /// could measure fall back to the measured tokens-per-weight ratio.
    static func apply(
        items: inout [ProviderContextItem], requests: [(items: [Int], context: Int?)], preassigned: [Int: Int] = [:]
    ) {
        var assigned = [Bool](repeating: false, count: items.count)
        for (id, tokens) in preassigned {
            items[id].tokens = tokens
            assigned[id] = true
        }
        var measuredTokens = 0
        var measuredWeight = 0
        for request in requests {
            guard let context = request.context, context > 0 else { continue }
            var seen = Set<Int>()
            var known = 0
            var fresh: [Int] = []
            for id in request.items where seen.insert(id).inserted {
                if assigned[id] { known += items[id].tokens } else { fresh.append(id) }
            }
            let remaining = context - known
            guard !fresh.isEmpty, remaining > 0 else { continue }
            distribute(remaining, over: fresh, items: &items)
            for id in fresh { assigned[id] = true }
            measuredTokens += remaining
            measuredWeight += fresh.reduce(0) { $0 + items[$1].weight }
        }
        let ratio = measuredWeight > 0 ? Double(measuredTokens) / Double(measuredWeight) : 0.25
        for id in items.indices where !assigned[id] {
            items[id].tokens = Int((Double(items[id].weight) * ratio).rounded())
        }
    }

    /// Shares `tokens` by weight; the rounding remainder goes to the heaviest item.
    static func distribute(_ tokens: Int, over ids: [Int], items: inout [ProviderContextItem]) {
        let total = ids.reduce(0) { $0 + items[$1].weight }
        guard total > 0, let heaviest = ids.max(by: { items[$0].weight < items[$1].weight }) else { return }
        var given = 0
        for id in ids {
            let share = Int(Int64(tokens) * Int64(items[id].weight) / Int64(total))
            items[id].tokens = share
            given += share
        }
        items[heaviest].tokens += tokens - given
    }

    /// Ratio measured only from requests that append to the one before them.
    static func appendRatio(items: [ProviderContextItem], deltas: [(items: [Int], tokens: Int)]) -> Double? {
        var tokens = 0
        var weight = 0
        for delta in deltas where delta.tokens > 0 {
            let added = delta.items.reduce(0) { $0 + items[$1].weight }
            guard added > 0 else { continue }
            tokens += delta.tokens
            weight += added
        }
        return weight > 0 ? Double(tokens) / Double(weight) : nil
    }
}

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
                querySource: object["querySource"] as? String
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
        for (index, request) in requests.enumerated() {
            var chain: [String] = []
            if let base = request.base, let baseIndex = indexByID[base] {
                chain = Array(chains[baseIndex].prefix(request.keep))
                if request.keep < chains[baseIndex].count { log.compactions += 1 }
            }
            chain += request.tail
            chains.append(chain)
            indexByID[request.id] = index
        }

        var sent: [(items: [Int], context: Int?)] = []
        log.sentRequests = requests.count
        for (index, request) in requests.enumerated() {
            let shapeItems = request.shapeHash.flatMap { shapes[$0] } ?? []
            let messageItems = chains[index].flatMap { blobs[$0] ?? [] }
            let ids = shapeItems + messageItems
            for id in Set(ids) { items[id].requests += 1 }
            let usage = usageByRequest[request.id]
            sent.append((ids, usage.map { $0.inputTokens + $0.cacheReadTokens + $0.cacheCreationTokens }))
            if let usage {
                log.requests.append(ProviderRequestUsage(
                    timestamp: request.timestamp,
                    contextTokens: usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    outputTokens: usage.outputTokens
                ))
            }
        }
        ProviderTokenCalibration.apply(items: &items, requests: sent)

        // Side queries (titles, summaries) have their own source; the
        // conversation is the source most requests share.
        let sources = Dictionary(grouping: requests.map { $0.querySource ?? "" }, by: { $0 }).mapValues(\.count)
        let mainSource = sources.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        if let last = requests.indices.last(where: { (requests[$0].querySource ?? "") == mainSource }) {
            var seen = Set<Int>()
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
        let ratio = ProviderTokenCalibration.appendRatio(items: items, deltas: deltas) ?? 0.25
        let first = records[0]
        let firstVisible = instructions + epochs[first.epoch][0..<first.boundary]
        let visibleEstimate = Int((Double(firstVisible.reduce(0) { $0 + items[$1].weight }) * ratio).rounded())
        let hiddenTokens = max(0, first.input - visibleEstimate)

        let sent = records.map { record -> (items: [Int], context: Int?) in
            ([hidden] + instructions + epochs[record.epoch][0..<record.boundary], record.input)
        }
        for request in sent {
            for id in Set(request.items) { items[id].requests += 1 }
        }
        ProviderTokenCalibration.apply(items: &items, requests: sent, preassigned: [hidden: hiddenTokens])
        log.requests = records.map {
            ProviderRequestUsage(timestamp: $0.timestamp, contextTokens: $0.input, cacheReadTokens: $0.cached, outputTokens: $0.output)
        }
        log.finalTranscript = sent[sent.count - 1].items
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
        let created = Entry(parser: provider == .claude ? ClaudeRequestLogParser() : CodexRolloutParser(), fileNumber: fileNumber)
        entries[file.path] = created
        while entries.count > Self.entryLimit, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
        return created
    }

    /// Full texts of several items, each line read and parsed once however many items it holds.
    func texts(of items: [ProviderContextItem], in log: ProviderAgentLog) -> [Int: String] {
        var result: [Int: String] = [:]
        guard let handle = try? FileHandle(forReadingFrom: log.file) else { return result }
        defer { try? handle.close() }
        let byLine = Dictionary(grouping: items.filter { $0.location != nil }, by: { $0.location?.offset ?? 0 })
        for (offset, lineItems) in byLine {
            autoreleasepool {
                guard let length = lineItems.first?.location?.length,
                      (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.read(upToCount: length),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return }
                for item in lineItems {
                    guard let path = item.location?.path else { continue }
                    result[item.id] = ProviderContextText.display(Self.value(at: path, in: object), kind: item.kind)
                }
            }
        }
        for item in items where item.location == nil { result[item.id] = item.preview }
        return result
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
        let key = "\(log.file.path)#\(item.id)"
        lock.lock()
        if let recent = recentTexts.first(where: { $0.key == key }) {
            lock.unlock()
            return recent.text
        }
        lock.unlock()
        var text = item.preview
        if let handle = try? FileHandle(forReadingFrom: log.file) {
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

// MARK: - Task token map

/// A provider session whose files a task's token map reads.
struct ProviderSessionReference: Sendable {
    let provider: ConversationProvider
    let sessionID: String
    /// Codex subagents run on their own threads, each with its own rollout file.
    let subagentThreadIDs: [String]
}

/// What wasted a task's tokens: the largest items, tools and MCP servers by
/// the tokens they added, what every request carries, repeats and cache misses.
struct TaskTokenWasteReport: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let provider: String
        let label: String
        let isMain: Bool
        let requests: Int
        let sentTokens: Int
        let finalTranscriptTokens: Int
        let items: Int
        let compactions: Int
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let item: Int
        let kind: String
        let label: String
        let server: String?
        let tokens: Int
        let requests: Int
        let rentTokens: Int
        let inFinalTranscript: Bool
        let preview: String
    }

    struct Tool: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let server: String?
        let calls: Int
        let totalTokens: Int
        let resultTokens: Int
        let largestResultTokens: Int
        let averageResultTokens: Int
        let rentTokens: Int
    }

    struct Server: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let tools: Int
        let calls: Int
        let totalTokens: Int
        let definitionTokens: Int
    }

    struct Overhead: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let label: String
        let kind: String
        let tokens: Int
        let requests: Int
        let everyRequest: Bool
        let item: Int?
    }

    struct Duplicate: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let item: Int
        let label: String
        let copies: Int
        let tokensPerCopy: Int
        let wastedTokens: Int
    }

    struct CacheMiss: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let request: Int
        let timestamp: String?
        let contextTokens: Int
        /// Tokens the previous request already sent that this one did not read from cache.
        let rewrittenTokens: Int
    }

    let taskID: UUID
    let available: Bool
    let agents: [Agent]
    let wasters: [Item]
    let tools: [Tool]
    let servers: [Server]
    let overhead: [Overhead]
    let duplicates: [Duplicate]
    let cacheMisses: [CacheMiss]
}

/// One page of an agent's context, without the items' full text.
struct TaskRawInputPage: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        let kind: String
        let role: String
        let label: String
        let server: String?
        let tokens: Int
        let requests: Int
        let rentTokens: Int
        let inFinalTranscript: Bool
        let textLength: Int
        let preview: String
    }

    let taskID: UUID
    let agent: String?
    let agents: [TaskTokenWasteReport.Agent]
    let scope: String
    let order: String
    let query: String
    let total: Int
    let totalTokens: Int
    let maxTokens: Int
    let offset: Int
    let rows: [Row]
    /// Where the requested focus item sits in this ordering, so a caller can load up to it.
    let focusPosition: Int?
}

/// One chunk of an item's full text, as the model received it.
struct TaskRawInputText: Codable, Equatable, Sendable {
    let taskID: UUID
    let agent: String
    let item: Int
    let kind: String
    let label: String
    let tokens: Int
    let requests: Int
    /// For a tool result, the call that produced it.
    let call: String?
    let totalLength: Int
    let offset: Int
    let nextOffset: Int?
    let text: String
}

enum TaskRawInputScope: String, CaseIterable, Sendable {
    case finalTranscript = "final"
    case everything = "all"
}

enum TaskRawInputOrder: String, CaseIterable, Sendable {
    case transcript
    case size
    case rent
}

enum ProviderTokenMap {
    struct LoadedAgent: Sendable {
        let id: String
        let label: String
        let isMain: Bool
        let log: ProviderAgentLog
    }

    static let defaultTextChunk = 32_768
    private static let listLimit = 20

    /// Reads every agent of the given sessions; agents whose files hold no request log are left out.
    static func load(
        sessions: [ProviderSessionReference], homes: ProviderSessionHomes, store: ProviderRequestLogStore = .shared
    ) -> [LoadedAgent] {
        var agents: [LoadedAgent] = []
        for session in sessions {
            let provider = session.provider.rawValue
            var files: [(id: String, label: String, isMain: Bool, file: URL)] = []
            switch session.provider {
            case .claude:
                guard let main = ClaudeSessionUsageReader.sessionFile(sessionID: session.sessionID, configDirectory: homes.claudeConfigDirectory) else { continue }
                files.append((provider, "Claude main agent", true, main))
                for subagent in ClaudeSessionUsageReader.subagentFiles(mainFile: main) {
                    files.append(("\(provider)/\(subagent.agentID)", "Claude subagent \(subagent.agentID)", false, subagent.file))
                }
            case .codex:
                if let main = store.codexRolloutFile(threadID: session.sessionID, codexHome: homes.codexHome) {
                    files.append((provider, "Codex main agent", true, main))
                }
                for thread in session.subagentThreadIDs.sorted() {
                    if let file = store.codexRolloutFile(threadID: thread, codexHome: homes.codexHome) {
                        files.append(("\(provider)/\(thread)", "Codex subagent \(thread)", false, file))
                    }
                }
            }
            for file in files {
                guard let log = store.log(provider: session.provider, file: file.file), log.isAvailable else { continue }
                agents.append(LoadedAgent(id: file.id, label: file.label, isMain: file.isMain, log: log))
            }
        }
        return agents
    }

    static func agentSummaries(_ agents: [LoadedAgent]) -> [TaskTokenWasteReport.Agent] {
        agents.map {
            TaskTokenWasteReport.Agent(
                id: $0.id, provider: $0.log.provider.rawValue, label: $0.label, isMain: $0.isMain,
                requests: $0.log.sentRequests, sentTokens: $0.log.sentTokens,
                finalTranscriptTokens: $0.log.finalTranscriptTokens,
                items: $0.log.items.filter { $0.requests > 0 }.count, compactions: $0.log.compactions
            )
        }
    }

    static func wasteReport(taskID: UUID, agents: [LoadedAgent]) -> TaskTokenWasteReport {
        var sent: [(agent: LoadedAgent, item: ProviderContextItem)] = []
        for agent in agents {
            for item in agent.log.items where item.requests > 0 { sent.append((agent, item)) }
        }
        func reportItem(_ agent: LoadedAgent, _ item: ProviderContextItem) -> TaskTokenWasteReport.Item {
            TaskTokenWasteReport.Item(
                id: "\(agent.id)#\(item.id)", agent: agent.id, item: item.id, kind: item.kind.rawValue,
                label: item.label, server: item.server, tokens: item.tokens, requests: item.requests,
                rentTokens: item.tokens * item.requests, inFinalTranscript: item.inFinalTranscript, preview: item.preview
            )
        }

        // Ranked by size: when an item arrived is chance, how much it added is the tool's doing.
        let wasters = sent
            .filter { !$0.item.kind.isFixedOverhead }
            .sorted { (lhs: (agent: LoadedAgent, item: ProviderContextItem), rhs: (agent: LoadedAgent, item: ProviderContextItem)) -> Bool in
                if lhs.item.tokens != rhs.item.tokens { return lhs.item.tokens > rhs.item.tokens }
                if lhs.agent.id != rhs.agent.id { return lhs.agent.id < rhs.agent.id }
                return lhs.item.id < rhs.item.id
            }
            .prefix(listLimit)
            .map { reportItem($0.agent, $0.item) }

        let toolItems = sent.filter { $0.item.kind == .toolCall || $0.item.kind == .toolResult }
        var tools: [TaskTokenWasteReport.Tool] = []
        for (label, entries) in Dictionary(grouping: toolItems, by: { $0.item.label }) {
            let results = entries.map(\.item).filter { $0.kind == .toolResult }
            let resultTokens = results.reduce(0) { $0 + $1.tokens }
            tools.append(TaskTokenWasteReport.Tool(
                id: label, server: entries.first?.item.server,
                calls: entries.filter { $0.item.kind == .toolCall }.count,
                totalTokens: entries.reduce(0) { $0 + $1.item.tokens },
                resultTokens: resultTokens,
                largestResultTokens: results.map(\.tokens).max() ?? 0,
                averageResultTokens: results.isEmpty ? 0 : resultTokens / results.count,
                rentTokens: entries.reduce(0) { $0 + $1.item.tokens * $1.item.requests }
            ))
        }
        tools.sort { $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.id < $1.id }

        let mains = agents.filter(\.isMain)
        var definitions: [ProviderContextItem] = []
        for agent in mains {
            definitions += agent.log.finalTranscript.map { agent.log.items[$0] }.filter { $0.kind == .toolDefinition }
        }
        let serverNames = Set(toolItems.compactMap(\.item.server) + definitions.compactMap(\.server))
        var servers: [TaskTokenWasteReport.Server] = []
        for server in serverNames {
            let used = toolItems.map(\.item).filter { $0.server == server }
            let defined = definitions.filter { $0.server == server }
            let labels = Set(used.map(\.label) + defined.map(\.label))
            servers.append(TaskTokenWasteReport.Server(
                id: server,
                tools: labels.count,
                calls: used.filter { $0.kind == .toolCall }.count,
                totalTokens: used.reduce(0) { $0 + $1.tokens },
                definitionTokens: defined.reduce(0) { $0 + $1.tokens }
            ))
        }
        servers.sort { lhs, rhs in
            let left = lhs.totalTokens + lhs.definitionTokens
            let right = rhs.totalTokens + rhs.definitionTokens
            return left != right ? left > right : lhs.id < rhs.id
        }

        var overhead: [TaskTokenWasteReport.Overhead] = []
        for agent in mains {
            let fixed = agent.log.finalTranscript.map { agent.log.items[$0] }.filter(\.kind.isFixedOverhead)
            for item in fixed where item.server == nil {
                overhead.append(.init(
                    id: "\(agent.id)#\(item.id)", agent: agent.id,
                    label: item.kind == .toolDefinition ? "Tool definition: \(item.label)" : item.label,
                    kind: item.kind.rawValue, tokens: item.tokens, requests: item.requests,
                    everyRequest: item.requests == agent.log.sentRequests, item: item.id
                ))
            }
            for (server, group) in Dictionary(grouping: fixed.filter { $0.server != nil }, by: { $0.server ?? "" }) {
                let requests = group.map(\.requests).max() ?? 0
                overhead.append(.init(
                    id: "\(agent.id)#mcp:\(server)", agent: agent.id,
                    label: "MCP server \(server) · \(group.count) tool definition\(group.count == 1 ? "" : "s")",
                    kind: ProviderContextKind.toolDefinition.rawValue, tokens: group.reduce(0) { $0 + $1.tokens },
                    requests: requests, everyRequest: requests == agent.log.sentRequests, item: nil
                ))
            }
        }
        overhead.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }

        var duplicates: [TaskTokenWasteReport.Duplicate] = []
        for agent in agents {
            let results = agent.log.items.filter { $0.kind == .toolResult && $0.requests > 0 && $0.textLength > 0 }
            for copies in Dictionary(grouping: results, by: { "\($0.contentKey):\($0.textLength)" }).values where copies.count > 1 {
                let ordered = copies.sorted { $0.id < $1.id }
                duplicates.append(.init(
                    id: "\(agent.id)#\(ordered[0].id)", agent: agent.id, item: ordered[0].id, label: ordered[0].label,
                    copies: ordered.count, tokensPerCopy: ordered[0].tokens,
                    wastedTokens: ordered.dropFirst().reduce(0) { $0 + $1.tokens }
                ))
            }
        }
        duplicates.sort { $0.wastedTokens != $1.wastedTokens ? $0.wastedTokens > $1.wastedTokens : $0.id < $1.id }

        // New content is always sent uncached. A miss is a request that sent
        // more than half of what the previous one already sent without reading
        // it from cache, so it paid for that prefix again.
        var cacheMisses: [TaskTokenWasteReport.CacheMiss] = []
        for agent in agents {
            for (index, (previous, request)) in zip(agent.log.requests, agent.log.requests.dropFirst()).enumerated() {
                let added = max(0, request.contextTokens - previous.contextTokens)
                let rewritten = request.contextTokens - request.cacheReadTokens - added
                guard rewritten >= 1_000, rewritten * 2 >= previous.contextTokens else { continue }
                cacheMisses.append(.init(
                    id: "\(agent.id)#request:\(index + 2)", agent: agent.id, request: index + 2, timestamp: request.timestamp,
                    contextTokens: request.contextTokens, rewrittenTokens: rewritten
                ))
            }
        }
        cacheMisses.sort { $0.rewrittenTokens != $1.rewrittenTokens ? $0.rewrittenTokens > $1.rewrittenTokens : $0.id < $1.id }

        return TaskTokenWasteReport(
            taskID: taskID, available: !agents.isEmpty, agents: agentSummaries(agents),
            wasters: Array(wasters), tools: tools, servers: servers, overhead: overhead,
            duplicates: Array(duplicates.prefix(listLimit)), cacheMisses: Array(cacheMisses.prefix(listLimit))
        )
    }

    static func page(
        taskID: UUID, agents: [LoadedAgent], agent: String?, scope: TaskRawInputScope, order: TaskRawInputOrder,
        query: String, offset: Int, limit: Int, focus: Int?, store: ProviderRequestLogStore = .shared
    ) throws -> TaskRawInputPage {
        let summaries = agentSummaries(agents)
        guard let loaded = try resolve(agent, in: agents) else {
            return TaskRawInputPage(
                taskID: taskID, agent: nil, agents: summaries, scope: scope.rawValue, order: order.rawValue, query: query,
                total: 0, totalTokens: 0, maxTokens: 0, offset: offset, rows: [], focusPosition: nil
            )
        }
        let items = loaded.log.items
        var ids: [Int]
        switch scope {
        case .finalTranscript:
            ids = loaded.log.finalTranscript
        case .everything:
            // Everything ever sent, in the order it was first logged; Codex's hidden overhead leads.
            ids = items.filter { $0.requests > 0 }
                .sorted { ($0.kind == .hiddenOverhead ? -1 : $0.id) < ($1.kind == .hiddenOverhead ? -1 : $1.id) }
                .map(\.id)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let unmatched = ids.map { items[$0] }.filter {
                !$0.label.localizedCaseInsensitiveContains(needle) && !$0.preview.localizedCaseInsensitiveContains(needle)
            }
            let texts = store.texts(of: unmatched, in: loaded.log)
            let misses = Set(unmatched.map(\.id).filter { !(texts[$0]?.localizedCaseInsensitiveContains(needle) ?? false) })
            ids = ids.filter { !misses.contains($0) }
        }
        switch order {
        case .transcript: break
        case .size:
            ids = ids.enumerated().sorted { lhs, rhs in
                items[lhs.element].tokens != items[rhs.element].tokens
                    ? items[lhs.element].tokens > items[rhs.element].tokens : lhs.offset < rhs.offset
            }.map(\.element)
        case .rent:
            ids = ids.enumerated().sorted { lhs, rhs in
                let left = items[lhs.element].tokens * items[lhs.element].requests
                let right = items[rhs.element].tokens * items[rhs.element].requests
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        let window = ids.dropFirst(offset).prefix(limit)
        return TaskRawInputPage(
            taskID: taskID, agent: loaded.id, agents: summaries, scope: scope.rawValue, order: order.rawValue, query: needle,
            total: ids.count, totalTokens: ids.reduce(0) { $0 + items[$1].tokens },
            maxTokens: ids.map { items[$0].tokens }.max() ?? 0, offset: offset,
            rows: window.map { id in
                let item = items[id]
                return TaskRawInputPage.Row(
                    id: id, kind: item.kind.rawValue, role: item.role, label: item.label, server: item.server,
                    tokens: item.tokens, requests: item.requests, rentTokens: item.tokens * item.requests,
                    inFinalTranscript: item.inFinalTranscript, textLength: item.textLength, preview: item.preview
                )
            },
            focusPosition: focus.flatMap { ids.firstIndex(of: $0) }
        )
    }

    static func text(
        taskID: UUID, agents: [LoadedAgent], agent: String?, item id: Int, offset: Int, length: Int,
        store: ProviderRequestLogStore = .shared
    ) throws -> TaskRawInputText {
        guard let loaded = try resolve(agent, in: agents),
              loaded.log.items.indices.contains(id), loaded.log.items[id].requests > 0 else {
            throw BridgeCommandError(code: "not_found", message: "No item \(id) was sent in this task's context.")
        }
        let item = loaded.log.items[id]
        let scalars = Array(store.text(of: item, in: loaded.log).unicodeScalars)
        let start = min(offset, scalars.count)
        let window = min(length, scalars.count - start)
        var end = start + window
        // A chunk that is not the last ends on a line break, so lines are never split between chunks.
        if end < scalars.count, let newline = scalars[(start + window / 2)..<end].lastIndex(of: "\n") {
            end = newline + 1
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<end])
        let call = item.callItemID.map { callID -> String in
            let callItem = loaded.log.items[callID]
            let arguments = store.text(of: callItem, in: loaded.log)
            return "\(callItem.label) \(arguments.count > 2_000 ? String(arguments.prefix(1_999)) + "…" : arguments)"
        }
        return TaskRawInputText(
            taskID: taskID, agent: loaded.id, item: id, kind: item.kind.rawValue, label: item.label,
            tokens: item.tokens, requests: item.requests, call: call, totalLength: scalars.count,
            offset: start, nextOffset: end < scalars.count ? end : nil, text: String(text)
        )
    }

    /// `nil` picks the first agent; an unknown agent is an error rather than an empty answer.
    private static func resolve(_ agent: String?, in agents: [LoadedAgent]) throws -> LoadedAgent? {
        guard let agent, !agent.isEmpty else { return agents.first }
        guard let loaded = agents.first(where: { $0.id == agent }) else {
            throw BridgeCommandError(code: "not_found", message: "This task has no agent named \(agent).")
        }
        return loaded
    }
}

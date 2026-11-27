import Foundation

extension PlayhouseBridgeRuntime {
    package static func diagnosticRequestFields(_ request: BridgeRequest) -> [String: String] {
        var fields = [
            "requestID": request.id,
            "command": request.command,
            "argumentCount": String(request.arguments.count),
            "argumentNames": request.arguments.keys.sorted().joined(separator: ",")
        ]
        for (key, value) in request.arguments {
            let normalizedKey = key.lowercased()
            if normalizedKey == "images", case .array(let values) = value {
                fields["argument.\(key).provided"] = "true"
                fields["argument.\(key).itemCount"] = String(values.count)
                for (index, value) in values.enumerated() {
                    guard case .string(let dataURL) = value,
                          dataURL.hasPrefix("data:image/"),
                          let separator = dataURL.firstIndex(of: ",") else { continue }
                    let metadata = dataURL[..<separator]
                    let mime = metadata.dropFirst("data:".count).split(separator: ";", maxSplits: 1).first.map(String.init) ?? "unknown"
                    fields["argument.\(key).\(index).mime"] = mime
                    fields["argument.\(key).\(index).encodedCharacterCount"] = String(dataURL[dataURL.index(after: separator)...].count)
                }
                continue
            }
            if ["message", "text", "prompt", "body", "summary", "answers", "images", "content"].contains(normalizedKey) {
                fields["argument.\(key).provided"] = "true"
                switch value {
                case .string(let text): fields["argument.\(key).utf8Bytes"] = String(text.utf8.count)
                case .array(let values): fields["argument.\(key).itemCount"] = String(values.count)
                case .object(let values): fields["argument.\(key).itemCount"] = String(values.count)
                default: break
                }
                continue
            }
            switch value {
            case .string(let string):
                fields["argument.\(key)"] = string
            case .integer(let number):
                fields["argument.\(key)"] = String(number)
            case .decimal(let number):
                fields["argument.\(key)"] = String(number)
            case .boolean(let boolean):
                fields["argument.\(key)"] = String(boolean)
            case .array(let values):
                fields["argument.\(key).itemCount"] = String(values.count)
                let strings = values.compactMap(\.string)
                if strings.count == values.count {
                    fields["argument.\(key).values"] = strings.joined(separator: "\n")
                }
                for (index, item) in values.enumerated() {
                    guard case .object(let itemFields) = item else { continue }
                    fields["argument.\(key).\(index).fieldNames"] = itemFields.keys.sorted().joined(separator: ",")
                    for (itemKey, itemValue) in itemFields {
                        let itemField = "argument.\(key).\(index).\(itemKey)"
                        let normalizedItemKey = itemKey.lowercased()
                        if ["message", "text", "prompt", "body", "summary", "answers", "images", "content"].contains(normalizedItemKey) {
                            fields["\(itemField).provided"] = "true"
                            continue
                        }
                        switch itemValue {
                        case .string(let string): fields[itemField] = string
                        case .integer(let number): fields[itemField] = String(number)
                        case .decimal(let number): fields[itemField] = String(number)
                        case .boolean(let boolean): fields[itemField] = String(boolean)
                        case .array(let nested): fields["\(itemField).itemCount"] = String(nested.count)
                        case .object(let nested): fields["\(itemField).itemCount"] = String(nested.count)
                        case .null: fields["\(itemField).isNull"] = "true"
                        }
                    }
                }
            case .object(let values):
                fields["argument.\(key).itemCount"] = String(values.count)
                fields["argument.\(key).subkeys"] = values.keys.sorted().joined(separator: "\n")
            case .null:
                fields["argument.\(key).isNull"] = "true"
            }
        }
        if let dataDirectory = request.dataDirectory { fields["dataDirectory"] = dataDirectory }
        if let worktreeDirectory = request.worktreeDirectory { fields["worktreeDirectory"] = worktreeDirectory }
        return fields
    }

    package static func diagnosticResultFields(_ result: BridgeValue) -> [String: String] {
        switch result {
        case .object(let values):
            var fields = ["resultKind": "object", "resultFieldCount": String(values.count)]
            for key in ["id", "status", "taskStatus", "command", "count"] {
                if let value = values[key]?.string { fields["result.\(key)"] = value }
                else if let value = values[key] {
                    switch value {
                    case .integer(let number): fields["result.\(key)"] = String(number)
                    case .boolean(let boolean): fields["result.\(key)"] = String(boolean)
                    default: break
                    }
                }
            }
            return fields
        case .array(let values):
            return ["resultKind": "array", "resultItemCount": String(values.count)]
        case .string(let value):
            return ["resultKind": "string", "resultUTF8Bytes": String(value.utf8.count)]
        case .integer, .decimal, .boolean:
            return ["resultKind": "scalar"]
        case .null:
            return ["resultKind": "null"]
        }
    }

    package static func elapsedMilliseconds(since start: UInt64) -> String {
        String((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    /// A standalone chat owns no repositories or worktree roots. It is not a task, so these
    /// commands could only ever fail for it; rejecting by chat identity reports why, instead
    /// of the bare "task not found" the `BoardTask` lookup would otherwise produce.
    package static func rejectStandaloneChat(_ taskManager: BoardTaskManager, _ taskID: UUID) throws {
        guard try taskManager.standaloneChatModel(taskID) != nil else { return }
        throw BridgeCommandError(code: "invalid_argument", message: "Standalone chat does not support repositories or worktree roots.")
    }

    package static func decode<T: Decodable>(_ value: BridgeValue?) throws -> T {
        guard let value else {
            throw BridgeCommandError(code: "invalid_argument", message: "A required argument is missing.")
        }
        return try value.decoded(T.self)
    }

    package static func value<T: Encodable>(_ value: T) throws -> BridgeValue {
        let data = try JSONEncoder.bridge.encode(value)
        return try JSONDecoder().decode(BridgeValue.self, from: data)
    }

    package static func autoCompactionValue(_ settings: ContextCompactionSettings) -> BridgeValue {
        .object([
            "enabled": .boolean(settings.enabled),
            "idleMinutes": .integer(settings.idleMinutes),
            "minimumTokens": .integer(settings.minimumTokens),
        ])
    }
}

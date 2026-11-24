import Foundation

/// Structured output for an agent whose provider has none of its own (OpenCode): the prompt
/// carries the plugin's JSON schema and asks for an answer of only matching JSON, and the
/// answer is read back and checked against the schema here. The check covers the keywords
/// plugins' schemas use (`type`, `properties`, `required`, `additionalProperties`, `items`,
/// `enum`, `const`, `anyOf`, `oneOf`, `allOf`, and the length, count and range bounds); a
/// keyword it doesn't know constrains nothing.
enum PluginJSONSchema {
    enum Checked: Equatable {
        case valid(PluginValue)
        /// What was wrong, in words the agent is shown when asked to answer again.
        case invalid(String)
    }

    /// The plugin's prompt with the schema and the instruction to answer with it.
    static func prompt(_ prompt: String, schema: PluginValue) -> String {
        """
        \(prompt)

        Answer with only a JSON value that matches this JSON Schema, with no other text and no Markdown code block:
        \(pretty(schema))
        """
    }

    /// Asks again, in the same session, after an answer that didn't match.
    static func correction(_ problem: String, schema: PluginValue) -> String {
        """
        Your answer didn't match the JSON Schema: \(problem)
        Answer again with only a JSON value that matches this JSON Schema, with no other text and no Markdown code block:
        \(pretty(schema))
        """
    }

    /// The answer's JSON, if any, checked against the schema.
    static func check(_ answer: String, schema: PluginValue) -> Checked {
        guard let value = json(in: answer) else { return .invalid("the answer isn't JSON.") }
        if let problem = problem(value, schema: schema, at: "$") { return .invalid(problem) }
        return .valid(value)
    }

    /// The whole answer as JSON, else the content of its Markdown code block, else the span
    /// from its first `{` or `[` to the matching last `}` or `]`.
    static func json(in answer: String) -> PluginValue? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let fence = trimmed.range(of: "```"), let close = trimmed.range(of: "```", range: fence.upperBound..<trimmed.endIndex) {
            var block = trimmed[fence.upperBound..<close.lowerBound]
            // The fence's info string (`json`) runs to the end of its line.
            if let newline = block.firstIndex(of: "\n"), !block[..<newline].contains("{"), !block[..<newline].contains("[") {
                block = block[block.index(after: newline)...]
            }
            candidates.append(String(block))
        }
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = trimmed.firstIndex(of: Character(open)), let end = trimmed.lastIndex(of: Character(close)), start < end {
                candidates.append(String(trimmed[start...end]))
            }
        }
        for candidate in candidates {
            if let value = try? JSONDecoder().decode(PluginValue.self, from: Data(candidate.utf8)) { return value }
        }
        return nil
    }

    /// The first way `value` breaks `schema`, naming where (`$.items[2].title`), or nil.
    static func problem(_ value: PluginValue, schema: PluginValue, at path: String) -> String? {
        if case .bool(let allowed) = schema { return allowed ? nil : "\(path) isn't allowed." }
        guard let schema = schema.object else { return nil }
        if let type = schema["type"] {
            let types = type.array?.compactMap(\.string) ?? type.string.map { [$0] } ?? []
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                return "\(path) must be \(types.map(article).joined(separator: " or ")), not \(article(typeName(value)))."
            }
        }
        if let options = schema["enum"]?.array, !options.contains(value) {
            return "\(path) must be one of \(options.map(\.jsonText).joined(separator: ", "))."
        }
        if let constant = schema["const"], constant != value { return "\(path) must be \(constant.jsonText)." }
        if let all = schema["allOf"]?.array {
            for part in all { if let problem = problem(value, schema: part, at: path) { return problem } }
        }
        if let any = schema["anyOf"]?.array, !any.contains(where: { problem(value, schema: $0, at: path) == nil }) {
            return "\(path) matches none of the schemas it may match."
        }
        if let one = schema["oneOf"]?.array, one.filter({ problem(value, schema: $0, at: path) == nil }).count != 1 {
            return "\(path) must match exactly one of its schemas."
        }
        switch value {
        case .object(let object):
            for name in schema["required"]?.array?.compactMap(\.string) ?? [] where object[name] == nil {
                return "\(path) is missing the required property \"\(name)\"."
            }
            let properties = schema["properties"]?.object ?? [:]
            for name in object.keys.sorted() {
                let child = "\(path).\(name)"
                if let property = properties[name] {
                    if let problem = problem(object[name]!, schema: property, at: child) { return problem }
                } else if let additional = schema["additionalProperties"] {
                    if additional == .bool(false) { return "\(path) has the property \"\(name)\", which the schema doesn't allow." }
                    if let problem = problem(object[name]!, schema: additional, at: child) { return problem }
                }
            }
        case .array(let items):
            if let minimum = schema["minItems"]?.int, items.count < minimum { return "\(path) must have at least \(minimum) items." }
            if let maximum = schema["maxItems"]?.int, items.count > maximum { return "\(path) must have at most \(maximum) items." }
            if let item = schema["items"] {
                for (index, element) in items.enumerated() {
                    if let problem = problem(element, schema: item, at: "\(path)[\(index)]") { return problem }
                }
            }
        case .string(let text):
            if let minimum = schema["minLength"]?.int, text.count < minimum { return "\(path) must be at least \(minimum) characters long." }
            if let maximum = schema["maxLength"]?.int, text.count > maximum { return "\(path) must be at most \(maximum) characters long." }
        case .number(let number):
            if case .number(let minimum)? = schema["minimum"], number < minimum { return "\(path) must be at least \(minimum.formatted())." }
            if case .number(let maximum)? = schema["maximum"], number > maximum { return "\(path) must be at most \(maximum.formatted())." }
        case .null, .bool:
            break
        }
        return nil
    }

    private static func matches(_ value: PluginValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case ("integer", .number(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }

    private static func typeName(_ value: PluginValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private static func article(_ type: String) -> String {
        type == "null" ? "null" : (["a", "e", "i", "o", "u"].contains(type.prefix(1)) ? "an " : "a ") + type
    }

    private static func pretty(_ schema: PluginValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(schema)).flatMap { String(data: $0, encoding: .utf8) } ?? schema.jsonText
    }
}

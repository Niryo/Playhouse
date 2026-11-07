import Foundation

// The plugin core shares `BridgeValue` (Bridge/BridgeContract.swift) as its JSON
// value type for state, props, payloads and API results. Everything in
// Plugins/Core must build with only Foundation and JavaScriptCore: the
// `playhouse-plugin-dev` runner links nothing else (see scripts/build-bridge.sh).

extension BridgeValue {
    /// Parses JSON text into a value. Top-level fragments (`3`, `"x"`, `null`) are allowed.
    static func parsingJSON(_ text: String) throws -> BridgeValue {
        try JSONDecoder().decode(BridgeValue.self, from: Data(text.utf8))
    }

    /// Compact JSON text with stable key order, for logs, the runner and JS.
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .decimal(let value): value
        default: nil
        }
    }

    var array: [BridgeValue]? { if case .array(let value) = self { value } else { nil } }

    var isNull: Bool { if case .null = self { true } else { false } }

    /// JavaScript-style truthiness, used by `if` and the `!` binding operator.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .boolean(let value): value
        case .integer(let value): value != 0
        case .decimal(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }

    /// The text a binding interpolates into a larger string.
    var interpolatedText: String {
        switch self {
        case .null: ""
        case .string(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .integer(let value): String(value)
        case .decimal(let value):
            value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .array, .object: jsonText
        }
    }
}

/// Resolves a plugin's relative file props (`src`) against its folder.
enum PluginFiles {
    /// The file `path` names inside `directory`, or nil when it is absolute or climbs out of the folder.
    static func resolve(_ path: String, in directory: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }
}

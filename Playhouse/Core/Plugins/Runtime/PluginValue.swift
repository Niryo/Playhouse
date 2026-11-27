import Foundation

/// A JSON value as it crosses from the plugin's JavaScript into Swift: an op
/// field, an atom prop, or an event's value.
package enum PluginValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginValue])
    case object([String: PluginValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    package var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    package var int: Int? {
        // Int(exactly:) is nil for a fraction or a number outside Int's range (1e300), where Int(_:) would trap.
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    package var array: [PluginValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    package var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    package var object: [String: PluginValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Compact JSON with sorted keys, for logs and the CLI.
    package var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

import CryptoKit
import Foundation

struct SkillFrontmatter {
    var name: String?
    var description: String?
    var issue: String?

    /// One top-level frontmatter key, its value, and the lines it was read from.
    struct Entry {
        let key: String
        let value: String
        let lines: [String]
    }

    /// The lines between the opening and closing `---`, and the line index
    /// where the instructions start, or nil when there is no frontmatter.
    static func split(_ contents: String) -> (header: [String], bodyStart: Int, lines: [String])? {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return (Array(lines[1..<end]), end + 1, lines)
    }

    static func entries(_ header: [String]) -> [Entry] {
        var entries: [Entry] = []
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var raw = [line]
            if [">", "|", ">-", "|-", ">+", "|+", ""].contains(value) {
                var parts: [String] = []
                while index < header.count, header[index].hasPrefix(" ") || header[index].hasPrefix("\t") || header[index].isEmpty {
                    let part = header[index].trimmingCharacters(in: .whitespaces)
                    if !part.isEmpty { parts.append(part) }
                    raw.append(header[index])
                    index += 1
                }
                // A YAML list, such as allowed-tools given one tool per line.
                if value.isEmpty, !parts.isEmpty, parts.allSatisfy({ $0.hasPrefix("- ") }) {
                    value = parts.map { unquoted(String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ")
                } else {
                    value = parts.joined(separator: value.hasPrefix("|") ? "\n" : " ")
                }
            } else {
                value = Self.unquoted(value)
            }
            entries.append(Entry(key: key, value: value, lines: raw))
        }
        return entries
    }

    init(_ contents: String) {
        guard let header = Self.split(contents)?.header else {
            issue = "SKILL.md must start with frontmatter between --- lines that sets name and description."
            return
        }
        for entry in Self.entries(header) {
            switch entry.key {
            case "name": name = entry.value
            case "description": description = entry.value
            default: break
            }
        }
        if name?.isEmpty != false {
            issue = "SKILL.md frontmatter must set a name."
        } else if description?.isEmpty != false {
            issue = "SKILL.md frontmatter must set a description."
        }
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'"
            ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Structured SKILL.md

/// A SKILL.md split into the header fields the Skills page edits and the
/// instructions below them. Frontmatter Playhouse does not edit is kept as
/// written, so a structured edit never drops a provider's own keys.
struct SkillManifest: Codable, Equatable, Sendable {
    /// Optional fields of the open Agent Skills format. Both Claude Code and
    /// Codex accept them, and each ignores the ones it does not use.
    static let optionalKeys = ["license", "compatibility", "allowed-tools"]

    var name: String
    var description: String
    var fields: [String: String]
    var body: String
    /// Other frontmatter entries, verbatim and in order.
    var preservedFrontmatter: [String] = []

    init(name: String, description: String, fields: [String: String] = [:], body: String, preservedFrontmatter: [String] = []) {
        self.name = name
        self.description = description
        self.fields = fields
        self.body = body
        self.preservedFrontmatter = preservedFrontmatter
    }

    /// A file without frontmatter is all instructions, named after its folder.
    init(parsing contents: String, fallbackName: String) {
        guard let split = SkillFrontmatter.split(contents) else {
            self.init(name: fallbackName, description: "", body: contents.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        var name: String?
        var description = ""
        var fields: [String: String] = [:]
        var preserved: [String] = []
        for entry in SkillFrontmatter.entries(split.header) {
            switch entry.key {
            case "name": name = entry.value
            case "description": description = entry.value
            case let key where Self.optionalKeys.contains(key): fields[key] = entry.value
            default: preserved += entry.lines
            }
        }
        let body = split.lines[split.bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName, description: description,
                  fields: fields, body: body, preservedFrontmatter: preserved)
    }

    var contents: String {
        let summary = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var lines = ["---", "name: \(name)", "description: \(SkillFrontmatter.quoted(summary))"]
        for key in Self.optionalKeys {
            let value = fields[key]?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty { lines.append("\(key): \(SkillFrontmatter.quoted(value))") }
        }
        lines += preservedFrontmatter
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

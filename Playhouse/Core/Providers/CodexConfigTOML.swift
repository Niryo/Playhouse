import Foundation

/// Reads and edits the `[mcp_servers]` part of a Codex `config.toml`.
///
/// Only that part is touched: a server written as its own `[mcp_servers.<name>]`
/// table (Codex's own `codex mcp add` style) is replaced or removed line by line,
/// and every other line of the file, comments included, stays as written. A
/// server written inline (`name = { ... }` or dotted keys) is read but left for
/// the user to edit by hand.
package enum CodexConfigTOML {
    package struct Server {
        package let name: String
        package let table: [String: Any]
        /// Defined only through its own `[mcp_servers.<name>]` tables, so Playhouse can rewrite it.
        package let editable: Bool

        package init(name: String, table: [String: Any], editable: Bool) {
            self.name = name
            self.table = table
            self.editable = editable
        }
    }

    package struct ParseError: Error, LocalizedError {
        package let line: Int
        package let message: String
        package var errorDescription: String? { "Line \(line): \(message)" }

        package init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
    }

    // MARK: Reading

    /// Every MCP server the file defines, in the order they first appear.
    package static func servers(in text: String) throws -> [Server] {
        var parser = Parser(text)
        let document = try parser.parseDocument()
        let tables = document["mcp_servers"] as? [String: Any] ?? [:]
        return parser.serverOrder.compactMap { name in
            guard let table = tables[name] as? [String: Any] else { return nil }
            return Server(name: name, table: table, editable: !parser.inlineServers.contains(name))
        }
    }

    // MARK: Writing

    /// The file with `name`'s tables replaced by `table`, or appended when the
    /// file has none. Fails for a server written inline.
    package static func setting(server name: String, table: [String: Any], in text: String) throws -> String {
        var parser = Parser(text)
        _ = try parser.parseDocument()
        guard !parser.inlineServers.contains(name) else { throw inlineError(name) }
        let block = render(server: name, table: table)
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let sections = serverSections(of: name, in: lines)
        if let first = sections.first {
            for range in sections.reversed() { lines.removeSubrange(range) }
            let trailing = first.lowerBound < lines.count ? [""] : []
            lines.insert(contentsOf: block + trailing, at: first.lowerBound)
            return lines.joined(separator: "\n")
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        return (lines + block).joined(separator: "\n") + "\n"
    }

    /// The file without `name`'s tables, or nil when it has none to remove.
    package static func removing(server name: String, from text: String) throws -> String? {
        var parser = Parser(text)
        _ = try parser.parseDocument()
        guard !parser.inlineServers.contains(name) else { throw inlineError(name) }
        var lines = text.components(separatedBy: "\n")
        let sections = serverSections(of: name, in: lines)
        guard !sections.isEmpty else { return nil }
        for range in sections.reversed() { lines.removeSubrange(range) }
        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    private static func inlineError(_ name: String) -> BridgeCommandError {
        BridgeCommandError(
            code: "invalid_argument",
            message: "\(name) is written inline in Codex's config.toml, so Playhouse leaves it to you. Edit it there, or rewrite it as an [mcp_servers.\(name)] table."
        )
    }

    /// The line ranges of `[mcp_servers.<name>]` and its sub-tables, each from
    /// its header up to the next header, in file order.
    private static func serverSections(of name: String, in lines: [String]) -> [Range<Int>] {
        let headers = lines.indices.compactMap { index in headerPath(lines[index]).map { (index, $0) } }
        return headers.enumerated().compactMap { position, header in
            let path = header.1
            guard path.count >= 2, path[0] == "mcp_servers", path[1] == name else { return nil }
            let end = position + 1 < headers.count ? headers[position + 1].0 : lines.count
            return header.0..<end
        }
    }

    /// The key path of a `[table]` header line, or nil for any other line.
    /// Array-of-tables headers count as headers that belong to nobody.
    private static func headerPath(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        if trimmed.hasPrefix("[[") { return ["[["] }
        var parser = Parser(String(trimmed.dropFirst()))
        return try? parser.parseKeyPath()
    }

    package static func render(server name: String, table: [String: Any]) -> [String] {
        let prefix = "mcp_servers." + key(name)
        var lines = ["[\(prefix)]"]
        let leading = ["command", "args", "url"]
        let scalars = table.filter { !($0.value is [String: Any]) }
        let ordered = leading.filter { scalars[$0] != nil } + scalars.keys.filter { !leading.contains($0) }.sorted()
        for key in ordered { lines.append("\(Self.key(key)) = \(value(scalars[key]!))") }
        for (subName, sub) in table.compactMap({ entry in (entry.value as? [String: Any]).map { (entry.key, $0) } }).sorted(by: { $0.0 < $1.0 }) {
            lines += ["", "[\(prefix).\(key(subName))]"]
            for subKey in sub.keys.sorted() { lines.append("\(key(subKey)) = \(value(sub[subKey]!))") }
        }
        return lines
    }

    package static func key(_ name: String) -> String {
        name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? name : quoted(name)
    }

    package static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    package static func value(_ value: Any) -> String {
        switch value {
        case let text as String: return quoted(text)
        case let flag as Bool: return flag ? "true" : "false"
        case let number as NSNumber:
            if POSIX.isBoolean(number) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let list as [Any]: return "[" + list.map { Self.value($0) }.joined(separator: ", ") + "]"
        case let table as [String: Any]:
            return "{ " + table.keys.sorted().map { "\(key($0)) = \(Self.value(table[$0]!))" }.joined(separator: ", ") + " }"
        default: return quoted("\(value)")
        }
    }

    // MARK: Parser

    /// A TOML reader complete enough for Codex's config: tables, dotted and
    /// quoted keys, strings of every kind, numbers, booleans, dates (kept as
    /// text), arrays, and inline tables. Arrays of tables are skipped.
    private struct Parser {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private var line = 1
        /// Servers named under `[mcp_servers]`, in first-seen order.
        var serverOrder: [String] = []
        /// Servers defined at least partly outside their own `[mcp_servers.<name>]` tables.
        var inlineServers = Set<String>()

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        private var atEnd: Bool { index >= scalars.count }
        private var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }
        private func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }

        private mutating func advance() {
            if current == "\n" { line += 1 }
            index += 1
        }

        private func error(_ message: String) -> ParseError { ParseError(line: line, message: message) }

        private mutating func skipSpaces() {
            while let scalar = current, scalar == " " || scalar == "\t" { advance() }
        }

        private mutating func skipComment() {
            if current == "#" { while let scalar = current, scalar != "\n" { advance() } }
        }

        /// Whitespace, comments, and newlines, as between statements or array items.
        private mutating func skipBlank() {
            while let scalar = current {
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { advance() }
                else if scalar == "#" { skipComment() }
                else { break }
            }
        }

        private mutating func endOfStatement() throws {
            skipSpaces()
            skipComment()
            if current == "\r" { advance() }
            guard atEnd || current == "\n" else { throw error("Expected the end of the line.") }
        }

        mutating func parseDocument() throws -> [String: Any] {
            var root: [String: Any] = [:]
            var table: [String]? = []
            while true {
                skipBlank()
                guard let scalar = current else { break }
                if scalar == "[" {
                    advance()
                    if current == "[" {
                        advance()
                        _ = try parseKeyPath()
                        guard current == "]", peek(1) == "]" else { throw error("Expected ]] after an array of tables.") }
                        advance(); advance()
                        table = nil
                    } else {
                        let path = try parseKeyPath()
                        guard current == "]" else { throw error("Expected ] after a table name.") }
                        advance()
                        table = path
                        if path.count >= 2, path[0] == "mcp_servers" { noteServer(path[1], inline: false) }
                        try Self.ensureTable(&root, path)
                    }
                    try endOfStatement()
                    continue
                }
                let key = try parseKeyPath()
                guard current == "=" else { throw error("Expected = after a key.") }
                advance()
                skipSpaces()
                let value = try parseValue()
                try endOfStatement()
                guard let table else { continue }
                let full = table + key
                if full.count >= 2, full[0] == "mcp_servers" {
                    noteServer(full[1], inline: table.count < 2)
                }
                try Self.assign(&root, full, value)
            }
            return root
        }

        private mutating func noteServer(_ name: String, inline: Bool) {
            if !serverOrder.contains(name) { serverOrder.append(name) }
            if inline { inlineServers.insert(name) }
        }

        mutating func parseKeyPath() throws -> [String] {
            var path: [String] = []
            while true {
                skipSpaces()
                guard let scalar = current else { throw error("Expected a key.") }
                if scalar == "\"" { path.append(try parseBasicString()) }
                else if scalar == "'" { path.append(try parseLiteralString()) }
                else {
                    var bare = ""
                    while let next = current, Self.isBareKey(next) { bare.unicodeScalars.append(next); advance() }
                    guard !bare.isEmpty else { throw error("Expected a key.") }
                    path.append(bare)
                }
                skipSpaces()
                guard current == "." else { return path }
                advance()
            }
        }

        private static func isBareKey(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "_" || scalar == "-"
        }

        private mutating func parseValue() throws -> Any {
            guard let scalar = current else { throw error("Expected a value.") }
            switch scalar {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" { return try parseMultilineBasic() }
                return try parseBasicString()
            case "'":
                if peek(1) == "'", peek(2) == "'" { return try parseMultilineLiteral() }
                return try parseLiteralString()
            case "[": return try parseArray()
            case "{": return try parseInlineTable()
            default: return try parseBare()
            }
        }

        private mutating func parseBasicString() throws -> String {
            advance()
            var text = ""
            while let scalar = current {
                if scalar == "\"" { advance(); return text }
                if scalar == "\n" { break }
                if scalar == "\\" { advance(); try appendEscape(&text); continue }
                text.unicodeScalars.append(scalar)
                advance()
            }
            throw error("A string is missing its closing quote.")
        }

        private mutating func parseLiteralString() throws -> String {
            advance()
            var text = ""
            while let scalar = current {
                if scalar == "'" { advance(); return text }
                if scalar == "\n" { break }
                text.unicodeScalars.append(scalar)
                advance()
            }
            throw error("A string is missing its closing quote.")
        }

        private mutating func parseMultilineBasic() throws -> String {
            advance(); advance(); advance()
            if current == "\n" { advance() } else if current == "\r", peek(1) == "\n" { advance(); advance() }
            var text = ""
            while let scalar = current {
                if scalar == "\"", peek(1) == "\"", peek(2) == "\"" {
                    advance(); advance(); advance()
                    while current == "\"" { text.append("\""); advance() }
                    return text
                }
                if scalar == "\\" {
                    advance()
                    if let next = current, next == "\n" || next == " " || next == "\t" || next == "\r" {
                        while let blank = current, blank == "\n" || blank == " " || blank == "\t" || blank == "\r" { advance() }
                        continue
                    }
                    try appendEscape(&text)
                    continue
                }
                text.unicodeScalars.append(scalar)
                advance()
            }
            throw error("A multi-line string is missing its closing quotes.")
        }

        private mutating func parseMultilineLiteral() throws -> String {
            advance(); advance(); advance()
            if current == "\n" { advance() } else if current == "\r", peek(1) == "\n" { advance(); advance() }
            var text = ""
            while let scalar = current {
                if scalar == "'", peek(1) == "'", peek(2) == "'" {
                    advance(); advance(); advance()
                    while current == "'" { text.append("'"); advance() }
                    return text
                }
                text.unicodeScalars.append(scalar)
                advance()
            }
            throw error("A multi-line string is missing its closing quotes.")
        }

        private mutating func appendEscape(_ text: inout String) throws {
            guard let scalar = current else { throw error("A string ends inside an escape.") }
            advance()
            switch scalar {
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "r": text.append("\r")
            case "b": text.append("\u{08}")
            case "f": text.append("\u{0C}")
            case "e": text.append("\u{1B}")
            case "\"": text.append("\"")
            case "\\": text.append("\\")
            case "u", "U":
                let count = scalar == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<count {
                    guard let digit = current else { throw error("A unicode escape is cut short.") }
                    hex.unicodeScalars.append(digit)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let value = Unicode.Scalar(code) else { throw error("\\\(scalar)\(hex) is not a character.") }
                text.unicodeScalars.append(value)
            default:
                throw error("\\\(scalar) is not a TOML escape.")
            }
        }

        private mutating func parseArray() throws -> [Any] {
            advance()
            var items: [Any] = []
            while true {
                skipBlank()
                if current == "]" { advance(); return items }
                items.append(try parseValue())
                skipBlank()
                if current == "," { advance(); continue }
                if current == "]" { advance(); return items }
                throw error("Expected , or ] in an array.")
            }
        }

        private mutating func parseInlineTable() throws -> [String: Any] {
            advance()
            var table: [String: Any] = [:]
            skipSpaces()
            if current == "}" { advance(); return table }
            while true {
                let key = try parseKeyPath()
                guard current == "=" else { throw error("Expected = in an inline table.") }
                advance()
                skipSpaces()
                try Self.assign(&table, key, try parseValue())
                skipSpaces()
                if current == "," { advance(); continue }
                if current == "}" { advance(); return table }
                throw error("Expected , or } in an inline table.")
            }
        }

        private mutating func parseBare() throws -> Any {
            var text = ""
            while let scalar = current, !(scalar == "," || scalar == "]" || scalar == "}" || scalar == "\n" || scalar == "#" || scalar == "\r") {
                text.unicodeScalars.append(scalar)
                advance()
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if text == "true" { return true }
            if text == "false" { return false }
            let plain = text.replacingOccurrences(of: "_", with: "")
            if let integer = Int(plain) { return integer }
            if plain.hasPrefix("0x"), let integer = Int(plain.dropFirst(2), radix: 16) { return integer }
            if let number = Double(plain), !plain.isEmpty { return number }
            guard !text.isEmpty else { throw error("Expected a value.") }
            // Dates and times keep their text.
            return text
        }

        private static func ensureTable(_ root: inout [String: Any], _ path: [String]) throws {
            guard let first = path.first else { return }
            var child = root[first] as? [String: Any] ?? [:]
            if root[first] != nil, !(root[first] is [String: Any]) {
                throw ParseError(line: 0, message: "\(first) is both a value and a table.")
            }
            try ensureTable(&child, Array(path.dropFirst()))
            root[first] = child
        }

        private static func assign(_ root: inout [String: Any], _ path: [String], _ value: Any) throws {
            guard let first = path.first else { return }
            if path.count == 1 {
                root[first] = value
                return
            }
            var child = root[first] as? [String: Any] ?? [:]
            if root[first] != nil, !(root[first] is [String: Any]) {
                throw ParseError(line: 0, message: "\(first) is both a value and a table.")
            }
            try assign(&child, Array(path.dropFirst()), value)
            root[first] = child
        }
    }
}

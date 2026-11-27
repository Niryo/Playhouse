import Foundation

/// The one Markdown parser in the app. It splits Markdown into blocks (headings, bullet and
/// ordered list items, quotes, fenced code, pipe tables, rules and paragraphs) and, when asked,
/// reads a leading YAML frontmatter block into its entries. Inline syntax (bold, italic, code,
/// links) stays in each block's text for `MarkdownInlineText` to style. The `Markdown` atom, and
/// so the transcript, the skill and rule previews and the side chat, renders from it.
/// Foundation only, so the pure-logic unit checks compile it on its own.
package struct MarkdownDocument: Equatable {
    package struct FrontmatterEntry: Equatable {
        package let key: String
        package let value: String

        package init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    package var frontmatter: [FrontmatterEntry] = []
    package var blocks: [MarkdownBlock]

    /// With `frontmatter`, a leading `---` block is read as entries instead of Markdown; its
    /// blocks keep the line numbers of the whole text.
    package init(_ markdown: String, frontmatter: Bool = false) {
        if frontmatter, let split = SkillFrontmatter.split(markdown) {
            self.frontmatter = SkillFrontmatter.entries(split.header).map { FrontmatterEntry(key: $0.key, value: $0.value) }
            blocks = Self.blocks(lines: Array(split.lines[split.bodyStart...]), firstLine: split.bodyStart)
        } else {
            blocks = Self.blocks(markdown)
        }
    }

    package static func blocks(_ markdown: String) -> [MarkdownBlock] {
        blocks(lines: markdown.components(separatedBy: .newlines), firstLine: 0)
    }

    /// Splits a Markdown table row on `|`, dropping an optional leading/trailing pipe the way
    /// GFM tables are usually written (`| a | b |` as well as the bare `a | b`).
    package static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns the per-column alignment if `line` is a valid GFM table separator row (each cell is
    /// dashes with optional leading/trailing colon, e.g. `---`, `:---`, `:---:`, `---:`), or `nil`
    /// if it isn't a separator row at all.
    package static func tableSeparatorAlignments(_ line: String) -> [MarkdownTableColumnAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableColumnAlignment] = []
        for cell in cells {
            var body = cell
            let leadingColon = body.hasPrefix(":")
            if leadingColon { body.removeFirst() }
            let trailingColon = body.hasSuffix(":")
            if trailingColon { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    package static func orderedListPrefix(_ line: Substring) -> (number: Int, rest: Substring)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (number, afterDigits.dropFirst(2))
    }

    /// Whether a link in rendered Markdown may leave the app: web and mail links open in their
    /// default apps, and any other scheme (a file, another app's URL) in plugin text does nothing.
    package static func opensLink(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A thematic break: three or more of the same `-`, `*` or `_`, spaces allowed between them.
    package static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Block ids are source line indexes (offset by `firstLine`); the transcript stores comments
    /// against them, so a block's id must not change while its text doesn't.
    private static func blocks(lines rawLines: [String], firstLine: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var paragraphStart: Int?
        // Treat digit-dot-space prefixes as an ordered list when they start a block (any number,
        // as in CommonMark) or start at 1 while a paragraph is open, then increment by one;
        // otherwise a wrapped sentence like "3. 5 billion parameters…" would be mis-parsed.
        var lastOrderedNumber: Int?

        func append(_ line: Int, _ kind: MarkdownBlock.Kind, _ text: String) {
            blocks.append(MarkdownBlock(id: firstLine + line, kind: kind, text: text))
        }

        func flushParagraph() {
            guard let start = paragraphStart, !paragraphLines.isEmpty else { return }
            append(start, .paragraph, paragraphLines.joined(separator: " "))
            paragraphLines.removeAll()
            paragraphStart = nil
        }

        var index = 0
        while index < rawLines.count {
            let rawLine = rawLines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                // A blank line alone does not end an ordered list: Markdown allows a "loose"
                // list with blank lines between items, so `lastOrderedNumber` carries across
                // this gap and only resets once a non-list block actually interrupts it.
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                lastOrderedNumber = nil
                let fenceStart = index
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                // Only a line consisting solely of backticks closes the fence, matching
                // CommonMark; a mere `hasPrefix("```")` would also match content lines inside the
                // code block itself (e.g. a code sample that demonstrates Markdown fences).
                while index < rawLines.count {
                    let candidate = rawLines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= 3, candidate.allSatisfy({ $0 == "`" }) { break }
                    codeLines.append(rawLines[index])
                    index += 1
                }
                if index < rawLines.count { index += 1 } // consume closing fence
                append(fenceStart, .codeBlock(language: language.isEmpty ? nil : language), codeLines.joined(separator: "\n"))
                continue
            }
            if line.contains("|"), index + 1 < rawLines.count,
               let alignments = tableSeparatorAlignments(rawLines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = tableCells(line)
                // A separator row with a different cell count than the header isn't a valid GFM
                // table (e.g. a stray "---" thematic break after a line that merely contains "|");
                // fall through to the normal paragraph/heading/list handling below instead.
                if headers.count == alignments.count {
                    flushParagraph()
                    lastOrderedNumber = nil
                    let tableStart = index
                    index += 2 // consume the header row and the separator row
                    var rows: [[String]] = []
                    while index < rawLines.count {
                        let rowLine = rawLines[index].trimmingCharacters(in: .whitespaces)
                        guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                        // GFM pads short rows and drops extra cells, so every row renders with the
                        // header's column count; without this a ragged row would shift the Grid's
                        // remaining columns out of alignment with their headers.
                        var cells = tableCells(rowLine)
                        if cells.count > headers.count { cells.removeSubrange(headers.count...) }
                        cells.append(contentsOf: Array(repeating: "", count: max(0, headers.count - cells.count)))
                        rows.append(cells)
                        index += 1
                    }
                    append(tableStart, .table(headers: headers, alignments: alignments, rows: rows), "")
                    continue
                }
            }
            if line.range(of: #":(?:playhouse-annotation|codex-annotation)\{index=\"\d+\"\}"#, options: .regularExpression) != nil {
                flushParagraph()
                lastOrderedNumber = nil
                append(index, .paragraph, line)
                index += 1
                continue
            }
            if line.hasPrefix(">") {
                // Consecutive quoted lines read as one quote; a bare ">" line splits it in two.
                flushParagraph()
                lastOrderedNumber = nil
                var quoteStart: Int?
                var quoteLines: [String] = []
                func flushQuote() {
                    if let start = quoteStart, !quoteLines.isEmpty { append(start, .quote, quoteLines.joined(separator: " ")) }
                    quoteStart = nil
                    quoteLines.removeAll()
                }
                while index < rawLines.count {
                    let quoted = rawLines[index].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    let content = quoted.dropFirst().trimmingCharacters(in: .whitespaces)
                    if content.isEmpty {
                        flushQuote()
                    } else {
                        quoteStart = quoteStart ?? index
                        quoteLines.append(content)
                    }
                    index += 1
                }
                flushQuote()
                continue
            }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                flushParagraph()
                lastOrderedNumber = nil
                append(index, .heading(headingPrefix.count), String(line.dropFirst(headingPrefix.count + 1)))
            } else if isRule(line) {
                flushParagraph()
                lastOrderedNumber = nil
                append(index, .rule, "")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                lastOrderedNumber = nil
                append(index, .listItem, String(line.dropFirst(2)))
            } else if let ordered = orderedListPrefix(line[...]),
                      // As in CommonMark, only a list starting at 1 may interrupt a paragraph,
                      // so a wrapped line that happens to begin "3. " stays part of its paragraph.
                      // With no paragraph open, a new list may start at any number.
                      paragraphLines.isEmpty || ordered.number == 1,
                      ordered.number == (lastOrderedNumber.map { $0 + 1 } ?? (paragraphLines.isEmpty ? ordered.number : 1)) {
                flushParagraph()
                lastOrderedNumber = ordered.number
                append(index, .orderedListItem(number: ordered.number), String(ordered.rest))
            } else {
                lastOrderedNumber = nil
                paragraphStart = paragraphStart ?? index
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }
}

package enum MarkdownTableColumnAlignment: Equatable {
    case leading, center, trailing
}

package struct MarkdownBlock: Identifiable, Equatable {
    package enum Kind: Equatable {
        case heading(Int)
        case listItem
        case orderedListItem(number: Int)
        /// A `>` quote; consecutive quoted lines join into one.
        case quote
        case codeBlock(language: String?)
        case table(headers: [String], alignments: [MarkdownTableColumnAlignment], rows: [[String]])
        /// A thematic break (`---`, `***`, `___`); its text is empty.
        case rule
        case paragraph

        /// Code blocks, tables and rules sit in their own boxes; the rest is running prose.
        package var isCard: Bool {
            switch self {
            case .codeBlock, .table, .rule: true
            case .heading, .listItem, .orderedListItem, .quote, .paragraph: false
            }
        }
    }

    /// The line it starts on.
    package let id: Int
    package let kind: Kind
    package let text: String

    package init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

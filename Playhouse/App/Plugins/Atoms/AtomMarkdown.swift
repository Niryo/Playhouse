import SwiftUI

/// Markdown rendered as formatted blocks, parsed by `MarkdownDocument` and styled by
/// `MarkdownInlineText`, the parser and inline styling the transcript uses; code blocks and
/// tables are the transcript's own cards. The skill and rule previews are built from it.
struct AtomMarkdown: View {
    var props = MarkdownProps()
    var common = AtomCommon()
    /// The raw string children, when `props.text` is unset.
    var children = ""

    private var size: CGFloat { CGFloat(props.size ?? 13) }

    var body: some View {
        let document = Self.document(props.text ?? children, frontmatter: props.frontmatter != nil)
        VStack(alignment: .leading, spacing: (size * 0.75).rounded()) {
            if props.frontmatter == "table", !document.frontmatter.isEmpty {
                frontmatterTable(document.frontmatter)
            }
            ForEach(document.blocks) { block in
                view(for: block)
            }
        }
        .atomForeground(props.color)
        .modifier(Applied(when: props.selectable == true) { $0.textSelection(.enabled) })
        .environment(\.openURL, OpenURLAction { url in MarkdownDocument.opensLink(url) ? .systemAction : .discarded })
        .atomCommon(common, atom: .markdown, group: true)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            let font = headingFont(level)
            MarkdownInlineText.text(block.text, baseFont: font)
                .font(Font(font as CTFont))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            prose(block.text)
        case .listItem:
            listItem(marker: "•", block.text)
        case .orderedListItem(let number):
            listItem(marker: "\(number).", block.text)
        case .quote:
            prose(block.text).markdownQuote()
        case .codeBlock(let language):
            CodeBlockCardView(blockID: block.id, code: block.text, language: language,
                              font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), identifierPrefix: common.testID)
        case .table(let headers, let alignments, let rows):
            TableBlockView(blockID: block.id, headers: headers, alignments: alignments, rows: rows, font: NSFont.systemFont(ofSize: size), identifierPrefix: common.testID)
        case .rule:
            MarkdownRule()
        }
    }

    private func prose(_ text: String) -> some View {
        MarkdownInlineText.text(text, baseFont: NSFont.systemFont(ofSize: size))
            .font(.system(size: size))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listItem(marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: marker)
                .font(.system(size: size).monospacedDigit())
            prose(text)
        }
        .padding(.leading, 8)
    }

    /// Headings scale from the body size: at 13 points, 17 bold, 15 semibold, then 13 bold.
    private func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: NSFont.systemFont(ofSize: size + 4, weight: .bold)
        case 2: NSFont.systemFont(ofSize: size + 2, weight: .semibold)
        default: NSFont.systemFont(ofSize: size, weight: .bold)
        }
    }

    private func frontmatterTable(_ entries: [MarkdownDocument.FrontmatterEntry]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                GridRow {
                    Text(verbatim: entry.key).font(.system(size: size - 3, weight: .semibold)).foregroundStyle(.secondary)
                    Text(verbatim: entry.value).font(.system(size: size - 1)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier("\(common.testID ?? "")-frontmatter") })
    }

    private final class CachedDocument {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    /// A re-render with the same text, as each keystroke in another field of the skill editor
    /// makes, reuses the parse.
    private static let cache: NSCache<NSString, CachedDocument> = {
        let cache = NSCache<NSString, CachedDocument>()
        cache.countLimit = 200
        return cache
    }()

    static func document(_ markdown: String, frontmatter: Bool) -> MarkdownDocument {
        let key = "\(frontmatter ? 1 : 0)|\(markdown)" as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        let document = MarkdownDocument(markdown, frontmatter: frontmatter)
        cache.setObject(CachedDocument(document), forKey: key)
        return document
    }
}

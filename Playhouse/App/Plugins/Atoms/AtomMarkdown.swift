import SwiftUI

/// Markdown rendered as formatted blocks, parsed by `MarkdownDocument` and styled by
/// `MarkdownStyle`: each run of prose (headings, paragraphs, lists, quotes) is one AppKit text
/// view, so a selection runs across its blocks, and each code block, table and rule is its own
/// card. It is the app's one Markdown renderer: the transcript's replies, the skill and rule
/// previews, the side chat and the question form are built from it. The transcript also passes
/// a `MarkdownTextHost`, which plugins can't, for its comments and side chats.
struct AtomMarkdown: View {
    var props = MarkdownProps()
    var common = AtomCommon()
    /// The raw string children, when `props.text` is unset.
    var children = ""
    var host: MarkdownTextHost? = nil

    private var style: MarkdownStyle { MarkdownStyle(size: CGFloat(props.size ?? 13)) }
    private var identifierPrefix: String? { host?.identifierPrefix ?? common.testID }
    private var selectable: Bool { props.selectable == true }

    var body: some View {
        #if PLAYHOUSE_ATOM_BENCHMARK
        let _ = AtomCounters.views += 1
        #endif
        let markdown = props.text ?? children
        let document = Self.document(markdown, frontmatter: props.frontmatter != nil, slot: host?.slot)
        let textColor = AtomColor.nsColor(props.color) ?? .labelColor
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            if props.frontmatter == "table", !document.frontmatter.isEmpty {
                frontmatterTable(document.frontmatter)
            }
            ForEach(MarkdownSegment.segments(of: document.blocks)) { segment in
                switch segment {
                case .prose(let blocks):
                    MarkdownProseText(
                        layout: MarkdownProseLayout.cached(
                            slot: host.map { "\($0.slot):\(blocks[0].id)" }, blocks: blocks, style: style, textColor: textColor,
                            identifierPrefix: identifierPrefix, responseAnnotations: host?.responseAnnotations ?? []
                        ),
                        style: style, textColor: textColor, selectable: selectable,
                        identifierPrefix: identifierPrefix, markdown: markdown, host: host
                    )
                case .card(let block):
                    card(block)
                }
            }
        }
        .atomForeground(props.color)
        // Table cells' links follow the prose's link rule.
        .modifier(Applied(when: host?.opensAnyLink != true) {
            $0.environment(\.openURL, OpenURLAction { url in MarkdownDocument.opensLink(url) ? .systemAction : .discarded })
        })
        .atomCommon(common, atom: .markdown, group: true)
    }

    @ViewBuilder
    private func card(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .codeBlock(let language):
            CodeBlockCardView(blockID: block.id, code: block.text, language: language,
                              font: style.codeFont, identifierPrefix: identifierPrefix)
                .cardIdentifier(identifierPrefix.map { "\($0)-code-block-\(block.id)" })
        case .table(let headers, let alignments, let rows):
            TableBlockView(blockID: block.id, headers: headers, alignments: alignments, rows: rows,
                           font: style.tableFont, identifierPrefix: identifierPrefix)
                // Each cell is its own selectable text, so its content can be copied like the prose around it.
                .modifier(Applied(when: selectable) { $0.textSelection(.enabled) })
        case .rule:
            MarkdownRule()
                .cardIdentifier(identifierPrefix.map { "\($0)-rule-\(block.id)" })
        case .heading, .listItem, .orderedListItem, .quote, .paragraph:
            EmptyView()
        }
    }

    private func frontmatterTable(_ entries: [MarkdownDocument.FrontmatterEntry]) -> some View {
        let size = style.size
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
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
        .modifier(Applied(when: selectable) { $0.textSelection(.enabled) })
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
    /// A hosted atom's parse, one per message, which a streaming reply replaces as it grows
    /// rather than filling the cache with each partial text.
    private static let slotCache = ReplyRenderCache<MarkdownDocument>(countLimit: 2000)

    static func document(_ markdown: String, frontmatter: Bool, slot: String? = nil) -> MarkdownDocument {
        if let slot {
            // Keyed by the text itself, without copying a long reply into a new key on every render.
            return slotCache.value(slot: frontmatter ? "\(slot)|frontmatter" : slot, key: markdown) {
                MarkdownDocument(markdown, frontmatter: frontmatter)
            }
        }
        let key = "\(frontmatter ? 1 : 0)|\(markdown)" as NSString
        if let cached = cache.object(forKey: key) { return cached.document }
        let document = MarkdownDocument(markdown, frontmatter: frontmatter)
        cache.setObject(CachedDocument(document), forKey: key)
        return document
    }
}

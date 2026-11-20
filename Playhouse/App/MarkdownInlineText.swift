import AppKit
import SwiftUI

/// Styles one `MarkdownBlock`'s inline Markdown (bold, italic, inline code, links), for the
/// transcript's text views and the `Markdown` atom alike.
enum MarkdownInlineText {
    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    /// Every transcript body re-evaluation re-renders each assistant block, so parsed Markdown is
    /// memoized by its exact inputs instead of being re-parsed for an unchanged block.
    /// Bounded because a streaming block adds a key for every partial text it passes through.
    private static let plainTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    private static let nsAttributedStringCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 500
        return cache
    }()

    static func plainText(_ markdown: String) -> String {
        if let cached = plainTextCache.object(forKey: markdown as NSString) {
            return cached as String
        }
        let text = String(attributed(markdown).characters)
        plainTextCache.setObject(text as NSString, forKey: markdown as NSString)
        return text
    }

    /// Bridges Markdown-parsed text to `NSAttributedString`, resizing inline code/bold/italic
    /// runs to `baseFont`'s point size (preserving their monospace/bold/italic traits) instead of
    /// the parser's own default-size font, so inline formatting matches the surrounding body text.
    static func nsAttributedString(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
        let cacheKey = "\(baseFont.fontName)|\(baseFont.pointSize)|\(markdown)" as NSString
        if let cached = nsAttributedStringCache.object(forKey: cacheKey) {
            return cached
        }
        let attributed = attributed(markdown)
        // Fonts are applied on the NSAttributedString because NSFont is not Sendable,
        // which AttributedString's AppKit font attribute requires.
        let result = NSMutableAttributedString(attributed)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let font: NSFont
            if intent.contains(.code) {
                // Slightly smaller than the prose, which a monospaced face reads larger than.
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                InlineCodeStyle.apply(to: result, range: NSRange(run.range, in: attributed))
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                guard !traits.isEmpty else { continue }
                font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
            }
            result.addAttribute(.font, value: font, range: NSRange(run.range, in: attributed))
        }
        nsAttributedStringCache.setObject(result, forKey: cacheKey)
        return result
    }

    /// The styled text as a SwiftUI `Text`. Runs without inline styling keep the `Text`'s own
    /// font and foreground, so the caller sets those for `baseFont`'s size and weight.
    static func text(_ markdown: String, baseFont: NSFont) -> Text {
        let formatted = NSMutableAttributedString(attributedString: nsAttributedString(markdown, baseFont: baseFont))
        // SwiftUI text has no pill drawing of its own; the inline code tint is drawn as a plain background.
        formatted.enumerateAttribute(InlineCodeStyle.attribute, in: NSRange(location: 0, length: formatted.length)) { value, range, _ in
            if let color = value as? NSColor { formatted.addAttribute(.backgroundColor, value: color, range: range) }
        }
        return Text((try? AttributedString(formatted, including: \.appKit)) ?? attributed(markdown))
    }
}

extension MarkdownTableColumnAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A thematic break between blocks.
struct MarkdownRule: View {
    var body: some View {
        Divider().padding(.vertical, 4)
            // A divider alone is no accessibility element, so the rule's identifier would be lost.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Horizontal rule")
    }
}

extension View {
    /// An accessibility identifier for a code or table card's part, or none.
    func cardIdentifier(_ identifier: String?) -> some View {
        modifier(Applied(when: identifier != nil) { $0.accessibilityIdentifier(identifier ?? "") })
    }

    /// A `>` quote: dimmed, indented past a bar down its leading edge.
    func markdownQuote() -> some View {
        foregroundStyle(.secondary)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
            }
    }
}

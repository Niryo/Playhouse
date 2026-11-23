import AppKit
import SwiftUI

/// Styles one `MarkdownBlock`'s inline Markdown (bold, italic, inline code, links), for the
/// `Markdown` atom's prose text views and its table cells.
enum MarkdownInlineText {
    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    /// Every re-render of an atom restyles each prose block, so the result is memoized by its
    /// exact inputs instead of being parsed again for an unchanged block. Bounded because a
    /// streaming block adds a key for every partial text it passes through.
    private static let nsAttributedStringCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 500
        return cache
    }()

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
}

#if os(macOS)
import AppKit
import PlayhouseCore
import SwiftUI

// Rich text styling: attributed strings with the platform fonts and colors that native text
// views draw. On macOS the attributes are AppKit's; a Linux build styles Pango attribute lists.

/// Inline `code` in conversation text: a tinted run on a rounded pill, as code editors show it.
package enum InlineCodeStyle {
    /// Marks inline code runs; its value is the pill's fill color.
    package static let attribute = NSAttributedString.Key("PlayhouseInlineCode")
    /// Room kept clear on each side of a run for its pill.
    package static let horizontalPadding: CGFloat = 4

    package static let textColor = PHPlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PHPlatformColor(srgbRed: 0.91, green: 0.79, blue: 0.56, alpha: 1)
            : PHPlatformColor(srgbRed: 0.66, green: 0.22, blue: 0.11, alpha: 1)
    }
    package static let backgroundColor = PHPlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PHPlatformColor.white.withAlphaComponent(0.09)
            : PHPlatformColor.black.withAlphaComponent(0.06)
    }

    /// Styles `range` of `text` as inline code. Kerning, not added characters, makes room for the
    /// pill, so comment offsets into the text are unchanged.
    package static func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        text.addAttributes([.foregroundColor: textColor, attribute: backgroundColor], range: range)
        text.addAttribute(.kern, value: horizontalPadding, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        if range.location > 0 {
            text.addAttribute(.kern, value: horizontalPadding, range: NSRange(location: range.location - 1, length: 1))
        }
    }
}

/// Styles one `MarkdownBlock`'s inline Markdown (bold, italic, inline code, links), for the
/// `Markdown` atom's prose text views and its table cells.
package enum MarkdownInlineText {
    package static func attributed(_ markdown: String) -> AttributedString {
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
    package static func nsAttributedString(_ markdown: String, baseFont: PHPlatformFont) -> NSAttributedString {
        let cacheKey = "\(baseFont.fontName)|\(baseFont.pointSize)|\(markdown)" as NSString
        if let cached = nsAttributedStringCache.object(forKey: cacheKey) {
            return cached
        }
        let attributed = attributed(markdown)
        // Fonts are applied on the NSAttributedString because PHPlatformFont is not Sendable,
        // which AttributedString's AppKit font attribute requires.
        let result = NSMutableAttributedString(attributed)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let font: PHPlatformFont
            if intent.contains(.code) {
                // Slightly smaller than the prose, which a monospaced face reads larger than.
                font = PHPlatformFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
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
#endif

import Foundation
import PlayhouseCore
import PlayhouseUI

extension MarkdownTableColumnAlignment {
    package var textAlignment: PHTextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A thematic break between blocks.
package struct MarkdownRule: PHView {
    package var body: some PHView {
        PHDivider().padding(.vertical, 4)
            // A divider alone is no accessibility element, so the rule's identifier would be lost.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Horizontal rule")
    }

    package init() {}
}

extension PHView {
    /// An accessibility identifier for a code or table card's part, or none.
    package func cardIdentifier(_ identifier: String?) -> some PHView {
        modifier(Applied(when: identifier != nil) { $0.accessibilityIdentifier(identifier ?? "") })
    }
}

/// Renders a parsed Markdown pipe table as a bordered grid instead of its raw `|`/`---` source,
/// following `CodeBlockCardView`'s card styling so tables visually match other assistant blocks.
package struct TableBlockView: PHView {
    package let blockID: Int
    package let headers: [String]
    package let alignments: [MarkdownTableColumnAlignment]
    package let rows: [[String]]
    package let font: PHPlatformFont
    /// Starts the card's accessibility identifiers (`<prefix>-…-<blockID>`); nil leaves them unset.
    /// A Markdown atom passes its own testID, so its cards never match the transcript's.
    package var identifierPrefix: String? = "assistant-markdown"

    private func alignment(forColumn column: Int) -> MarkdownTableColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// Maps a column's text alignment to the matching frame alignment, so the cell's text and its
    /// containing frame agree on where content sits (`.leading`/`.trailing` text alignment alone
    /// has no effect inside a frame that doesn't also pin content to that same edge).
    private func frameAlignment(forColumn column: Int) -> PHAlignment {
        switch alignment(forColumn: column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// The weight is applied here rather than by the caller because `cellText` already sets a
    /// `.font`, and the innermost `.font` modifier is the one SwiftUI honors — a `.semibold` font
    /// applied by the caller outside this view would be silently discarded.
    /// The vertical `fixedSize` lets a cell take the full height of its wrapped text; without it
    /// the `Grid` row settles on a shorter height and long cells are cut off with an ellipsis.
    private func cellText(_ cell: String, weight: PHFont.Weight = .regular) -> some PHView {
        let formatted = MarkdownInlineText.nsAttributedString(cell, baseFont: font)
        return PHText((try? AttributedString(formatted, including: \.appKit)) ?? AttributedString(cell))
            .font(.system(size: font.pointSize, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
    }

    package var body: some PHView {
        PHGrid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            PHGridRow {
                PHForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                    cellText(header, weight: .semibold)
                        .multilineTextAlignment(alignment(forColumn: column).textAlignment)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(forColumn: column))
                        .padding(8)
                        .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)-header-\(column)" })
                }
            }
            .background(WorkspaceTheme.inputBackground)

            PHDivider().opacity(0.3)

            PHForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                PHGridRow {
                    PHForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellText(cell)
                            .multilineTextAlignment(alignment(forColumn: column).textAlignment)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(forColumn: column))
                            .padding(8)
                            .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)-cell-\(rowIndex)-\(column)" })
                    }
                }
                if rowIndex < rows.count - 1 {
                    PHDivider().opacity(0.12)
                }
            }
        }
        .overlay(PHRoundedRectangle.phContinuous(cornerRadius: 10).strokeBorder(.secondary.opacity(0.25)))
        .clipShape(PHRoundedRectangle.phContinuous(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)" })
    }

    package init(blockID: Int, headers: [String], alignments: [MarkdownTableColumnAlignment], rows: [[String]], font: PHPlatformFont, identifierPrefix: String? = "assistant-markdown") {
        self.blockID = blockID
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
        self.font = font
        self.identifierPrefix = identifierPrefix
    }
}

package struct ResponseAnnotationReference {
    package let text: String
    package let comment: String

    package init(text: String, comment: String) {
        self.text = text
        self.comment = comment
    }
}

package struct CodeBlockCardView: PHView {
    package let blockID: Int
    package let code: String
    package let language: String?
    package let font: PHPlatformFont
    /// Starts the card's accessibility identifiers (`<prefix>-…-<blockID>`); nil leaves them unset.
    /// A Markdown atom passes its own testID, so its cards never match the transcript's.
    package var identifierPrefix: String? = "assistant-markdown"

    @PHState private var didCopy = false
    @PHState private var copyFeedbackToken = UUID()

    private var languageDisplayName: String {
        guard let language, !language.isEmpty else { return "Code" }
        return language.prefix(1).uppercased() + language.dropFirst()
    }

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 0) {
            PHHStack(spacing: 6) {
                PHImage(icon: .chevronLeftForwardslashChevronRight)
                    .font(.system(size: 12, weight: .semibold))
                PHText(languageDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .cardIdentifier(identifierPrefix.map { "\($0)-code-block-language-\(blockID)" })
                PHSpacer()
                PHButton {
                    Platform.services.copyToClipboard(code)
                    didCopy = true
                    let token = UUID()
                    copyFeedbackToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copyFeedbackToken == token { didCopy = false }
                    }
                } label: {
                    PHImage(icon: didCopy ? .checkmark : .docOnDoc)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .nativeHelp("Copy code")
                .accessibilityLabel("Copy code")
                .cardIdentifier(identifierPrefix.map { "\($0)-code-block-copy-\(blockID)" })
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            PHDivider().opacity(0.15)

            PHNativeCodeBlockText(attributedText: CodeSyntaxHighlighter.highlight(code, language: language, font: font))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(WorkspaceTheme.inputBackground, in: PHRoundedRectangle.phContinuous(cornerRadius: 10))
        // Keeps the language label and copy action identifiable inside the identified card.
        .accessibilityElement(children: .contain)
    }

    package init(blockID: Int, code: String, language: String?, font: PHPlatformFont, identifierPrefix: String? = "assistant-markdown") {
        self.blockID = blockID
        self.code = code
        self.language = language
        self.font = font
        self.identifierPrefix = identifierPrefix
    }
}

extension PHNativeSelectableText {
    /// The attributes that carry a resolved comment marker's quoted text and comment.
    package static let responseCommentTextKey = NSAttributedString.Key("PlayhouseResponseCommentText")
    package static let responseCommentBodyKey = NSAttributedString.Key("PlayhouseResponseCommentBody")

    package static func replaceResponseAnnotationMarkers(in value: NSMutableAttributedString, references: [ResponseAnnotationReference]) {
        let pattern = #":(?:playhouse-annotation|codex-annotation)\{index=\"(\d+)\"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let originalText = value.string as NSString
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: originalText.length)).reversed() {
            guard match.numberOfRanges > 1,
                  let index = Int(originalText.substring(with: match.range(at: 1))) else { continue }
            let label = match.range.location == 0 ? "\(index + 1)." : "Comment \(index + 1)"
            let isResolved = references.indices.contains(index)
            let replacement = NSMutableAttributedString(string: label, attributes: [
                .font: PHPlatformFont.systemFont(ofSize: 16),
                .foregroundColor: isResolved ? PHPlatformColor.controlAccentColor
                    : (value.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? PHPlatformColor ?? .labelColor),
            ])
            if isResolved {
                let reference = references[index]
                replacement.addAttribute(.underlineStyle,
                                         value: PHUnderlineStyle.single.rawValue | PHUnderlineStyle.patternDot.rawValue,
                                         range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentTextKey, value: reference.text, range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentBodyKey, value: reference.comment, range: NSRange(location: 0, length: replacement.length))
            }
            value.replaceCharacters(in: match.range, with: replacement)
        }
    }
}

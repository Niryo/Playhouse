import AppKit

enum CodeSyntaxHighlighter {
    /// Colors that switch between a dark-background-tuned palette and a light-background-tuned
    /// palette based on the code block's current effective appearance, mirroring the
    /// `WorkspaceTheme.adaptive` pattern used elsewhere for theme-aware colors.
    private enum Palette {
        private static func adaptive(dark: (UInt8, UInt8, UInt8), light: (UInt8, UInt8, UInt8)) -> NSColor {
            NSColor(name: nil) { appearance in
                let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(components.0) / 255,
                    green: CGFloat(components.1) / 255,
                    blue: CGFloat(components.2) / 255,
                    alpha: 1
                )
            }
        }

        static let keyword = adaptive(dark: (0xC5, 0x86, 0xE8), light: (0x9B, 0x23, 0x93))
        static let function = adaptive(dark: (0xB1, 0x80, 0xD7), light: (0x6F, 0x1D, 0xB3))
        static let string = adaptive(dark: (0x98, 0xC3, 0x79), light: (0xC4, 0x1A, 0x16))
        static let comment = adaptive(dark: (0x80, 0x80, 0x80), light: (0x6C, 0x6C, 0x6C))
        static let number = adaptive(dark: (0xD1, 0x9A, 0x66), light: (0x1C, 0x00, 0xCF))
        static let plain = adaptive(dark: (0xD9, 0xD9, 0xD9), light: (0x1A, 0x1A, 0x1A))
    }

    private static let jsLikeKeywords: Set<String> = [
        "function", "return", "const", "let", "var", "if", "else", "for", "while", "do",
        "class", "new", "import", "export", "default", "from", "await", "async", "try",
        "catch", "finally", "throw", "switch", "case", "break", "continue", "this",
        "typeof", "instanceof", "null", "undefined", "true", "false", "extends", "super",
        "static", "get", "set", "yield", "in", "of",
    ]

    private static let keywordsByLanguage: [String: Set<String>] = [
        "javascript": jsLikeKeywords,
        "js": jsLikeKeywords,
        "jsx": jsLikeKeywords,
        "typescript": jsLikeKeywords.union([
            "interface", "type", "implements", "public", "private", "protected",
            "readonly", "enum", "namespace", "as", "is", "keyof", "declare",
        ]),
        "ts": jsLikeKeywords.union(["interface", "type", "implements", "public", "private", "protected", "readonly", "enum", "namespace", "as"]),
        "tsx": jsLikeKeywords.union(["interface", "type", "implements", "public", "private", "protected", "readonly", "enum"]),
        "python": [
            "def", "return", "if", "elif", "else", "for", "while", "class", "import",
            "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield",
            "pass", "break", "continue", "True", "False", "None", "and", "or", "not", "in",
            "is", "global", "nonlocal", "async", "await", "self",
        ],
        "swift": [
            "func", "return", "if", "else", "for", "while", "class", "struct", "enum",
            "protocol", "import", "let", "var", "guard", "switch", "case", "break",
            "continue", "default", "try", "catch", "throw", "private", "public",
            "internal", "fileprivate", "static", "extension", "init", "self", "nil",
            "true", "false", "async", "await", "in", "where", "as", "is",
        ],
        "bash": [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "function",
            "return", "echo", "export", "local", "case", "esac", "in",
        ],
        "shell": [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "function",
            "return", "echo", "export", "local", "case", "esac", "in",
        ],
        "sh": [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "function",
            "return", "echo", "export", "local", "case", "esac", "in",
        ],
    ]

    private static let genericKeywords: Set<String> = [
        "function", "return", "if", "else", "for", "while", "class", "import", "export",
        "const", "let", "var", "true", "false", "null",
    ]

    /// Re-running every regex pass on each SwiftUI body re-evaluation (e.g. while sibling UI
    /// updates or the view scrolls) would redo the same work for an unchanged code block, so
    /// results are memoized by their exact inputs.
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func highlight(_ code: String, language: String?, font: NSFont) -> NSAttributedString {
        let cacheKey = "\(language ?? "")|\(font.pointSize)|\(code)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        let result = NSMutableAttributedString(
            string: code,
            attributes: [.font: font, .foregroundColor: Palette.plain]
        )
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        guard fullRange.length > 0 else { return result }

        func applyColor(_ color: NSColor, pattern: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: code, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        let language = (language ?? "").lowercased()

        let keywords = keywordsByLanguage[language] ?? genericKeywords
        let escapedKeywords = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        if !escapedKeywords.isEmpty {
            applyColor(Palette.keyword, pattern: "\\b(?:\(escapedKeywords))\\b")
        }

        // Mirrors Prism.js's "function" token: an identifier immediately followed by `(` is a
        // function/method call, e.g. the `log` in `console.log(...)`. Keywords are excluded so
        // `if (`/`for (`/`switch (` aren't recolored as calls.
        let keywordExclusion = escapedKeywords.isEmpty ? "" : "(?!(?:\(escapedKeywords))\\b)"
        applyColor(Palette.function, pattern: "\\b\(keywordExclusion)[A-Za-z_][A-Za-z0-9_]*(?=\\s*\\()")

        applyColor(Palette.number, pattern: #"\b\d+(\.\d+)?\b"#)

        applyColor(Palette.string, pattern: "\"\"\"[\\s\\S]*?\"\"\"")
        applyColor(Palette.string, pattern: "'''[\\s\\S]*?'''")
        applyColor(Palette.string, pattern: "\"(?:\\\\.|[^\"\\\\])*\"")
        applyColor(Palette.string, pattern: "'(?:\\\\.|[^'\\\\])*'")
        applyColor(Palette.string, pattern: "`(?:\\\\.|[^`\\\\])*`")

        switch language {
        case "python", "bash", "sh", "shell", "ruby", "yaml", "yml":
            applyColor(Palette.comment, pattern: "#.*$", options: [.anchorsMatchLines])
        case "json":
            break
        default:
            applyColor(Palette.comment, pattern: "//.*$", options: [.anchorsMatchLines])
            applyColor(Palette.comment, pattern: "/\\*[\\s\\S]*?\\*/")
        }

        result.addAttribute(.font, value: font, range: fullRange)
        cache.setObject(result, forKey: cacheKey)
        return result
    }
}

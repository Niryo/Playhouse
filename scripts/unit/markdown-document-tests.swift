import Foundation

// Pure-logic checks of the shared Markdown parser in Playhouse/Core/Conversation/MarkdownDocument.swift,
// compiled with it (and SkillManifest.swift, for frontmatter) and run by scripts/test-e2e.sh
// before the bridge suite. The transcript, the Markdown atom and the skill and rule previews
// all render from these blocks; the bridge case `test_plugin_renderer_commits_minimal_ops_and_runs_handlers`
// covers the atom's props and children end to end.

@main
struct MarkdownDocumentTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func kinds(_ blocks: [MarkdownBlock]) -> [MarkdownBlock.Kind] { blocks.map(\.kind) }

    static func main() {
        // Every block kind, with its line and text.
        let all = MarkdownDocument.blocks("""
        # Title
        A paragraph that
        wraps onto two lines with **bold**.

        - bullet
        * star
        1. one
        2. two
        > quoted
        > still quoted
        >
        > second quote
        ---
        ```swift
        let x = 1
        ```
        | a | b |
        |:--|--:|
        | 1 | 2 |
        ***
        """)
        expect(kinds(all), [
            .heading(1), .paragraph, .listItem, .listItem, .orderedListItem(number: 1), .orderedListItem(number: 2),
            .quote, .quote, .rule, .codeBlock(language: "swift"),
            .table(headers: ["a", "b"], alignments: [.leading, .trailing], rows: [["1", "2"]]), .rule,
        ], "Every block kind parses")
        expect(all.map(\.id), [0, 1, 4, 5, 6, 7, 8, 11, 12, 13, 16, 19], "Each block's id is the line it starts on")
        expect(all[1].text, "A paragraph that wraps onto two lines with **bold**.", "Paragraph lines join, inline syntax kept")
        expect(all[6].text, "quoted still quoted", "Consecutive quoted lines join into one quote")
        expect(all[7].text, "second quote", "A bare > line splits the quote")
        expect(all[9].text, "let x = 1", "A fenced block keeps its code")

        // The transcript's ordered-list rules: only a list starting at 1 interrupts a paragraph.
        expect(kinds(MarkdownDocument.blocks("Revenue grew to\n3. 5 billion")), [.paragraph], "A wrapped \"3. \" stays in its paragraph")
        expect(kinds(MarkdownDocument.blocks("Steps:\n1. a\n\n2. b")), [.paragraph, .orderedListItem(number: 1), .orderedListItem(number: 2)],
               "A loose list continues across a blank line")
        expect(kinds(MarkdownDocument.blocks("4. four\n5. five")), [.orderedListItem(number: 4), .orderedListItem(number: 5)], "A list may start at any number")

        // A fence closes only on a line of backticks, and an unclosed fence runs to the end.
        let fenced = MarkdownDocument.blocks("```\n```js inside\n```\nafter")
        expect(kinds(fenced), [.codeBlock(language: nil), .paragraph], "Only bare backticks close a fence")
        expect(fenced[0].text, "```js inside", "Fence-like content stays code")
        expect(MarkdownDocument.blocks("```\nopen").map(\.text), ["open"], "An unclosed fence keeps its code")

        // Rules and tables.
        expect(kinds(MarkdownDocument.blocks("- - -\n___\n**bold**")), [.rule, .rule, .paragraph], "Spaced and underscore rules; bold is no rule")
        expect(kinds(MarkdownDocument.blocks("a | b | c\n---")), [.paragraph, .rule], "A separator with the wrong cell count is no table")
        expect(kinds(MarkdownDocument.blocks("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")),
               [.table(headers: ["a", "b"], alignments: [.leading, .leading], rows: [["1", ""], ["1", "2"]])],
               "Short rows are padded and long rows trimmed to the header")
        expect(MarkdownDocument.tableSeparatorAlignments(":-:|-"), [.center, .leading], "Separator alignments")
        expect(MarkdownDocument.tableSeparatorAlignments("a|-"), nil, "A row of text is no separator")

        // Headings need a space and at most six marks.
        expect(kinds(MarkdownDocument.blocks("####### seven\n#tag\n###### six")), [.paragraph, .heading(6)], "Heading marks")

        // Frontmatter: read as entries when asked, otherwise Markdown like any other text.
        let skill = "---\nname: release-notes\ndescription: \"Draft notes\"\nmetadata:\n  owner: docs\n---\n\n# Release notes\n"
        let withFrontmatter = MarkdownDocument(skill, frontmatter: true)
        expect(withFrontmatter.frontmatter, [
            .init(key: "name", value: "release-notes"), .init(key: "description", value: "Draft notes"), .init(key: "metadata", value: "owner: docs"),
        ], "Frontmatter entries")
        expect(withFrontmatter.blocks, [MarkdownBlock(id: 7, kind: .heading(1), text: "Release notes")], "The body keeps its line numbers")
        let plain = MarkdownDocument(skill)
        expect(plain.frontmatter, [], "Without frontmatter reading there are no entries")
        expect(kinds(plain.blocks).first, .rule, "Unread frontmatter's fence is a rule")
        expect(MarkdownDocument("No frontmatter here", frontmatter: true).blocks.map(\.text), ["No frontmatter here"], "Text without frontmatter")
        expect(MarkdownDocument("", frontmatter: true).blocks, [], "Empty text has no blocks")

        // Links: only web and mail links leave the app.
        for (link, opens) in [("https://github.com", true), ("HTTP://example.com", true), ("mailto:a@b.c", true),
                              ("file:///etc/passwd", false), ("javascript:alert(1)", false), ("x-apple.systempreferences:", false), ("relative/path", false)] {
            expect(MarkdownDocument.opensLink(URL(string: link)!), opens, "Link \(link) opens")
        }

        if failures.isEmpty {
            print("Markdown document checks: \(checks) passed")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}

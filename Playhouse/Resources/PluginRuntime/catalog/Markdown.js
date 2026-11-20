// Markdown: formatted text from `text` (or string children): headings, lists, quotes, fenced code,
// tables, rules, bold, italic, inline code and links. `frontmatter` shows a leading YAML block as a
// table ("table") or hides it ("hide"); `size` sets the body text, `color` the prose, `selectable`
// lets the reader select it. The skill and rule editors' previews are this atom.
var skill = [
  "---",
  "name: release-notes",
  "description: Draft release notes",
  "---",
  "",
  "# Release notes",
  "",
  "Summarize **merged** changes from `git log`, *briefly*.",
  "",
  "- Group changes by area.",
  "- Link each [pull request](https://github.com).",
  "",
  "1. Collect the changes",
  "2. Write the notes",
  "",
  "> Keep it short.",
  "",
  "```swift",
  "let notes = changes.map(\\.title)",
  "```",
  "",
  "| Area | Changes |",
  "| :-- | --: |",
  "| App | 3 |",
  "",
  "---",
  "",
  "The end.",
].join("\n");

Playhouse.render(h(Stack, { axis: "v", spacing: 16, align: "leading", fillWidth: true },
  h(Markdown, { text: skill, frontmatter: "table", selectable: true, fillWidth: true, testID: "markdown-skill" }),
  h(Divider),
  h(Markdown, { text: "---\nname: hidden\n---\nOnly the **body** shows.", frontmatter: "hide", size: 11, color: "secondary", testID: "markdown-hidden-frontmatter" }),
  h(Markdown, { testID: "markdown-children" }, "## From string children\n", "A Markdown atom also reads its raw strings.")
));

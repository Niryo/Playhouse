// Link: opens `url` in the browser; its children are the label.
Playhouse.render(h(Stack, { axis: "h", spacing: 8 },
  h(Link, { url: "https://github.com/example/playhouse/pull/193", emphasis: 5, minWidth: 30, minHeight: 30, value: "pending", help: "playhouse · checks running", testID: "link-pending" },
    h(Text, { size: 10, weight: "semibold", design: "monospaced", color: "blue" }, "#193")),
  h(Link, { url: "https://github.com/example/playhouse/pull/188", emphasis: 5, minWidth: 30, minHeight: 30, value: "green" },
    h(Text, { size: 10, weight: "semibold", design: "monospaced", color: "green" }, "#188")),
  h(Link, { url: "https://github.com/example/playhouse/pull/170", emphasis: 5, minWidth: 30, minHeight: 30, value: "merged" },
    h(Text, { size: 10, weight: "semibold", design: "monospaced", color: "purple" }, "#170"))
));

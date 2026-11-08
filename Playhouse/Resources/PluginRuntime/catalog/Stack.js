// Stack: a row (axis "h") or column (axis "v", the default).
function Box(label) {
  return h(Text, { size: 11, weight: "medium", color: "accent", padding: 6 }, label);
}

Playhouse.render(h(Stack, { axis: "v", spacing: 16, align: "leading" },
  h(Text, { size: 11, color: "secondary" }, "axis: \"v\", align: \"leading\", spacing: 4"),
  h(Stack, { axis: "v", spacing: 4, align: "leading", testID: "stack-column" }, Box("One"), Box("Two"), Box("Three")),
  h(Text, { size: 11, color: "secondary" }, "axis: \"h\", spacing: 12"),
  h(Stack, { axis: "h", spacing: 12, testID: "stack-row" }, Box("One"), Box("Two"), Box("Three")),
  h(Text, { size: 11, color: "secondary" }, "axis: \"h\", align: \"top\", group: true (one accessibility container)"),
  h(Stack, { axis: "h", spacing: 6, align: "top", group: true, testID: "stack-group", label: "Grouped row" },
    h(Icon, { name: "sparkle", size: 10, color: "accent" }),
    h(Stack, { axis: "v", spacing: 2, align: "leading" },
      h(Text, { size: 10, weight: "semibold" }, "Top aligned"),
      h(Text, { size: 10, color: "secondary" }, "Second line"))),
  h(Text, { size: 11, color: "secondary" }, "fillWidth: true, padding: 8"),
  h(Stack, { axis: "h", fillWidth: true, padding: 8, testID: "stack-fill" }, Box("Leading in full width"))
));

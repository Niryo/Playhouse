// Stack: a row (axis "h") or column (axis "v", the default). It draws nothing
// unless a surface prop (fill, fillOpacity, cornerRadius, capsule, stroke,
// strokeOpacity, strokeWidth, dash) is set; then its frame and padding size
// the surface and its children sit inside it.
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
  h(Text, { size: 11, color: "secondary" }, "summary: true (one accessibility element read only as its label)"),
  h(Stack, { axis: "h", spacing: 6, summary: true, testID: "stack-summary", label: "Summarized notice" },
    h(Icon, { name: "info.circle", size: 10, color: "secondary" }),
    h(Text, { size: 10, color: "secondary" }, "Children hidden from accessibility")),
  h(Text, { size: 11, color: "secondary" }, "fillWidth: true, padding: 8"),
  h(Stack, { axis: "h", fillWidth: true, padding: 8, group: true, testID: "stack-fill" }, Box("Leading in full width")),
  h(Text, { size: 11, color: "secondary" }, "Surface, axis: \"v\": fill: \"accent\", fillOpacity: 0.18, cornerRadius: 8, stroke: \"accent\", minWidth: 220, minHeight: 90"),
  h(Stack, { axis: "v", spacing: 2, align: "leading", fill: "accent", fillOpacity: 0.18, cornerRadius: 8, stroke: "accent",
    minWidth: 220, minHeight: 90, padding: 8, group: true, testID: "stack-surface-column" },
    h(Text, { size: 11, weight: "semibold", testID: "stack-surface-column-first" }, "Children at the top leading"),
    h(Text, { size: 10, color: "secondary" }, "of a 90-point column")),
  h(Text, { size: 11, color: "secondary" }, "Surface, axis: \"h\": fill: \"#2E7D32\", capsule: true, dash: [4, 3]"),
  h(Stack, { axis: "h", spacing: 6, fill: "#2E7D32", capsule: true, stroke: "primary", strokeOpacity: 0.3, dash: [4, 3],
    paddingX: 10, paddingY: 5, group: true, testID: "stack-surface-row" },
    h(Icon, { name: "checkmark.circle.fill", size: 11, color: "white" }),
    h(Text, { size: 11, weight: "semibold", color: "white", testID: "stack-surface-row-text" }, "Decorated row")),
  h(Text, { size: 11, color: "secondary" }, "Surface, align unset (center), fillWidth: true, minHeight: 60, strokeWidth: 2 (a border only)"),
  h(Stack, { axis: "h", spacing: 4, strokeWidth: 2, cornerRadius: 12, fillWidth: true, minHeight: 60, group: true, testID: "stack-surface-center" },
    h(Text, { size: 11, testID: "stack-surface-center-text" }, "Centered both ways"))
));

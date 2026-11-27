// Stack: a row (axis "h"), column (axis "v", the default) or layers (axis
// "z"). It draws nothing unless a surface prop (fill, fillOpacity,
// cornerRadius, capsule, stroke, strokeOpacity, strokeWidth, dash, material,
// clip, shadow) is set; then its frame and padding size the surface and its
// children sit inside it. With an onHover handler it reports the pointer
// entering and leaving it.
function Box(label) {
  return h(Text, { size: 11, weight: "medium", color: "accent", padding: 6 }, label);
}

function HoverRow() {
  var hovering = React.useState(false);
  return h(Stack, { axis: "h", spacing: 6, fill: "primary", fillOpacity: hovering[0] ? 0.12 : 0.04, cornerRadius: 7, paddingX: 10, paddingY: 6,
    combine: true, testID: "stack-hover", label: hovering[0] ? "hovering" : "idle", onHover: function (isHovering) { hovering[1](isHovering === true || isHovering === "true"); } },
    h(Text, { size: 11, testID: "stack-hover-text" }, hovering[0] ? "Pointer over the row" : "Hover this row"));
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
,
  h(Text, { size: 11, color: "secondary" }, "axis: \"z\", align: \"topTrailing\" (layers)"),
  h(Stack, { axis: "z", align: "topTrailing", group: true, testID: "stack-layers" },
    h(Stack, { fill: "accent", fillOpacity: 0.15, cornerRadius: 8, width: 120, height: 50, summary: true, label: "Base", testID: "stack-layers-base" }, h(Text, { size: 11 }, "Base")),
    h(Stack, { fill: "red", capsule: true, width: 10, height: 10, decorative: true, testID: "stack-layers-badge" })),
  h(Text, { size: 11, color: "secondary" }, "material: \"regular\", shadow: 8, shadowOpacity: 0.2, shadowY: 3, clip: true"),
  h(Stack, { axis: "h", spacing: 6, material: "regular", cornerRadius: 12, clip: true, shadow: 8, shadowOpacity: 0.2, shadowY: 3,
    paddingX: 12, paddingY: 8, summary: true, label: "Translucent, shadowed", testID: "stack-material" },
    h(Text, { size: 11, weight: "medium" }, "Translucent, shadowed")),
  h(Text, { size: 11, color: "secondary" }, "onHover (hover state the owner keeps)"),
  h(HoverRow),
  h(Text, { size: 11, color: "secondary" }, "maxWidth: 160, frameAlign: \"trailing\", paddingTop: 6, paddingLeading: 12"),
  h(Stack, { axis: "h", fill: "primary", fillOpacity: 0.05, fillWidth: true, maxWidth: 160, frameAlign: "trailing", paddingTop: 6, paddingLeading: 12,
    summary: true, label: "Trailing", testID: "stack-edges" },
    h(Text, { size: 11, testID: "stack-edges-text" }, "Trailing"))
));

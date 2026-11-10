// Icon: an SF Symbol (`name`) or a template image from the app's assets (`asset`);
// `original` draws the asset in its own colors.
Playhouse.render(h(Stack, { axis: "v", spacing: 12, align: "leading" },
  h(Stack, { axis: "h", spacing: 14 },
    h(Icon, { name: "hammer", size: 10, weight: "semibold", color: "accent", testID: "icon-hammer", label: "hammer" }),
    h(Icon, { name: "clock", size: 10, color: "tertiary" }),
    h(Icon, { name: "checkmark", size: 11, weight: "bold", color: "green" }),
    h(Icon, { name: "sparkle", size: 14, color: "orange" }),
    h(Icon, { name: "chart.bar", size: 18 })),
  h(Text, { size: 11, color: "secondary" }, "asset: \"ConflictIndicator\", 16 × 16, orange"),
  h(Icon, { asset: "ConflictIndicator", color: "orange", width: 16, height: 16, testID: "icon-asset" }),
  h(Text, { size: 11, color: "secondary" }, "asset: \"PlayhouseLogo\", original colors, 50 × 50"),
  h(Icon, { asset: "PlayhouseLogo", original: true, width: 50, height: 50, label: "Playhouse logo", testID: "icon-asset-original" })
));

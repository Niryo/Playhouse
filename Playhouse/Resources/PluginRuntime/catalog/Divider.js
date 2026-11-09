// Divider: a thin separator line across the stack it sits in.
Playhouse.render(h(Stack, { axis: "v", spacing: 8, align: "leading", width: 220 },
  h(Text, { size: 11 }, "Above the line"),
  h(Divider, { testID: "divider-demo" }),
  h(Text, { size: 11, color: "secondary" }, "Below the line")));

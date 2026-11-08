// Spinner: indeterminate progress, small (default) or mini.
Playhouse.render(h(Stack, { axis: "h", spacing: 16 },
  h(Stack, { axis: "h", spacing: 6 }, h(Spinner, { testID: "spinner-small" }), h(Text, { size: 11, color: "secondary" }, "small")),
  h(Stack, { axis: "h", spacing: 6 }, h(Spinner, { size: "mini", testID: "spinner-mini" }), h(Text, { size: 11, color: "secondary" }, "mini"))
));

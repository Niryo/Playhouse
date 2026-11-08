// Text: a string from its children (or `text`), with size, weight, design, color and layout props.
function Counter() {
  var count = React.useState(1200);
  return h(Stack, { axis: "h", spacing: 8 },
    h(Text, { size: 13, design: "monospaced", numeric: true, testID: "text-numeric" }, String(count[0])),
    h(Button, { style: "borderless", testID: "text-increment", onPress: function () { count[1](count[0] + 345); } },
      h(Text, { size: 11, color: "accent" }, "Add 345")));
}

Playhouse.render(h(Stack, { axis: "v", spacing: 10, align: "leading" },
  h(Text, { size: 13, weight: "semibold", color: "text", tracking: 0.35, testID: "text-title" }, "Title: 13 semibold, tracking 0.35"),
  h(Text, { size: 10, weight: "semibold" }, "Label: 10 semibold"),
  h(Text, { size: 10, color: "secondary" }, "Detail: 10 secondary"),
  h(Text, { size: 10, color: "tertiary" }, "Meta: 10 tertiary"),
  h(Text, { size: 10, weight: "medium", design: "monospaced", color: "#C9A02E" }, "1.2M (monospaced, #C9A02E)"),
  h(Stack, { axis: "h", spacing: 8 },
    h(Text, { size: 11, color: "red" }, "red"),
    h(Text, { size: 11, color: "green" }, "green"),
    h(Text, { size: 11, color: "orange" }, "orange"),
    h(Text, { size: 11, color: "blue" }, "blue"),
    h(Text, { size: 11, color: "purple" }, "purple"),
    h(Text, { size: 11, color: "accent" }, "accent")),
  h(Text, { size: 10, color: "secondary", lineLimit: 2, width: 220 }, "lineLimit: 2 — a long status message that keeps going well past two lines, so it is cut off with an ellipsis at the end."),
  h(Text, { size: 11, wrap: true, width: 220 }, "wrap: true — this text grows vertically to fit instead of truncating."),
  h(Text, { text: "From the text prop", size: 11 }),
  h(Counter)
));

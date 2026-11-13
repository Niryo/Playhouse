// Popover: anchored to its first child, showing the rest while isPresented.
// It is controlled: a click outside or Escape calls onDismiss, and the owner
// then sets isPresented false. Its content is padded (inset, 14 by default)
// and spaced (spacing, 10 by default) with no padding of its own.
function Demo() {
  var open = React.useState(false);
  var last = React.useState("none");
  var overrideOpen = React.useState(false);
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Popover, { isPresented: open[0], arrowEdge: "bottom", width: 220, testID: "popover-demo", onDismiss: function () { open[1](false); last[1]("dismiss"); } },
      h(Button, { style: "bordered", width: 100, testID: "popover-anchor", onPress: function () { open[1](!open[0]); last[1]("toggle"); } },
        h(Text, { size: 12 }, "Open")),
      h(Text, { size: 12, weight: "semibold", testID: "popover-title" }, "Popover content"),
      h(Text, { size: 11, color: "secondary", wrap: true, testID: "popover-body" }, "Escape or a click outside closes it.")),
    h(Popover, { isPresented: overrideOpen[0], arrowEdge: "bottom", width: 220, inset: 0, spacing: 4, testID: "popover-override", onDismiss: function () { overrideOpen[1](false); } },
      h(Button, { style: "bordered", width: 100, testID: "popover-override-anchor", onPress: function () { overrideOpen[1](!overrideOpen[0]); } },
        h(Text, { size: 12 }, "Open override")),
      h(Text, { size: 12, weight: "semibold", testID: "popover-override-title" }, "Popover content"),
      h(Text, { size: 11, color: "secondary", wrap: true, testID: "popover-override-body" }, "Escape or a click outside closes it.")),
    h(Text, { size: 11, color: "secondary", testID: "popover-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

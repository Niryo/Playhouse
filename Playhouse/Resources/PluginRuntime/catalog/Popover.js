// Popover: anchored to its first child, showing its second while isPresented.
// It is controlled: a click outside or Escape calls onDismiss, and the owner
// then sets isPresented false.
function Demo() {
  var open = React.useState(false);
  var last = React.useState("none");
  return h(Stack, { axis: "h", spacing: 10 },
    h(Popover, { isPresented: open[0], arrowEdge: "bottom", width: 200, onDismiss: function () { open[1](false); last[1]("dismiss"); } },
      h(Button, { style: "bordered", testID: "popover-anchor", onPress: function () { open[1](!open[0]); last[1]("toggle"); } },
        h(Text, { size: 12 }, "Open")),
      h(Stack, { axis: "v", spacing: 6, padding: 12, align: "leading" },
        h(Text, { size: 12, weight: "semibold", testID: "popover-title" }, "Popover content"),
        h(Text, { size: 11, color: "secondary" }, "Escape or a click outside closes it."))),
    h(Text, { size: 11, color: "secondary", testID: "popover-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

// SidePanel: a full-height panel that slides in over one edge of its first
// child (trailing by default, or leading), `width` wide (340 by default), on
// the window background with a hairline along its inner edge and a shadow,
// while isPresented (the Done archive over the board). The first child stays
// laid out as usual and sizes the atom. It is controlled: the owner closes it
// with its own control, here the panel's close button.
function Demo() {
  var open = React.useState(false);
  var edge = React.useState("trailing");
  var last = React.useState("none");
  function close(how) { open[1](false); last[1](how); }
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(SidePanel, { isPresented: open[0], edge: edge[0], width: 200, testID: "side-panel-demo" },
      h(Stack, { axis: "v", spacing: 8, align: "leading", fill: "primary", fillOpacity: 0.04, cornerRadius: 8, width: 480, height: 240, paddingX: 16, paddingY: 16, group: true, testID: "side-panel-base" },
        h(Text, { size: 13, weight: "semibold" }, "The view the panel slides over"),
        h(Stack, { axis: "h", spacing: 8 },
          h(Button, { style: "bordered", testID: "side-panel-open-trailing", onPress: function () { edge[1]("trailing"); open[1](true); last[1]("open trailing"); } },
            h(Text, { size: 12 }, "Open trailing")),
          h(Button, { style: "bordered", testID: "side-panel-open-leading", onPress: function () { edge[1]("leading"); open[1](true); last[1]("open leading"); } },
            h(Text, { size: 12 }, "Open leading")))),
      h(Stack, { axis: "h", padding: 16 },
        h(Text, { size: 14, weight: "semibold", testID: "side-panel-title" }, "Panel"),
        h(Spacer),
        h(Button, { testID: "side-panel-close", label: "Close panel", help: "Close panel", onPress: function () { close("close"); } },
          h(Icon, { name: "xmark" }))),
      h(Divider),
      h(Text, { size: 11, color: "secondary", padding: 16, wrap: true }, "The close button closes it.")),
    h(Text, { size: 11, color: "secondary", testID: "side-panel-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

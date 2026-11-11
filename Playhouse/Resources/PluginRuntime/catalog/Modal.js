// Modal: a sheet over the window, presented from its first child (which stays
// laid out as usual) and showing the rest in a leading column while
// isPresented. It is controlled: Escape calls onDismiss, and the owner then
// sets isPresented false; the sheet's Done button closes it too.
function Demo() {
  var open = React.useState(false);
  var last = React.useState("none");
  function close(how) { open[1](false); last[1](how); }
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Modal, { isPresented: open[0], width: 320, testID: "modal-demo", onDismiss: function () { close("dismiss"); } },
      h(Button, { style: "bordered", testID: "modal-open", onPress: function () { open[1](true); last[1]("open"); } },
        h(Text, { size: 12 }, "Open modal")),
      h(Stack, { axis: "v", spacing: 8, padding: 20, align: "leading", fillWidth: true },
        h(Text, { size: 15, weight: "semibold", testID: "modal-title" }, "Modal content"),
        h(Text, { size: 11, color: "secondary", wrap: true }, "Escape or Done closes it.")),
      h(Divider),
      h(Stack, { axis: "h", padding: 14, fillWidth: true },
        h(Spacer),
        h(Button, { style: "prominent", shortcut: "default", testID: "modal-done", onPress: function () { close("done"); } },
          h(Text, null, "Done")))),
    h(Text, { size: 11, color: "secondary", testID: "modal-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

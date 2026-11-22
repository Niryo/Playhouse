// Modal: a sheet over the window, presented from its first child (which stays
// laid out as usual) and showing the rest in a leading column while
// isPresented. It is controlled: Escape and the header's close button call
// onDismiss, and the owner then sets isPresented false; the sheet's Done
// button closes it too. With a title the sheet starts with the app's standard
// header (icon, title, subtitle and close button), and its content is padded
// (inset, 24 by default) and spaced (spacing, 16 by default) with no padding
// of its own. The header is a convenience composition of a row Stack with an
// accent Icon, a column Stack of title and subtitle Text, a Spacer, and a Button
// containing an xmark Icon; its inset and spacing are a padded content Stack.
// With dismissible false the header has no close button and Escape does
// nothing, so only the owner's own control (Choose) closes it.
function Demo() {
  var open = React.useState(false);
  var last = React.useState("none");
  var overrideOpen = React.useState(false);
  var requiredOpen = React.useState(false);
  function close(how) { open[1](false); last[1](how); }
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Modal, {
      isPresented: open[0], width: 320, title: "Modal title", subtitle: "A standard header over padded content",
      icon: "macwindow", testID: "modal-demo", onDismiss: function () { close("dismiss"); }
    },
      h(Button, { style: "bordered", testID: "modal-open", onPress: function () { open[1](true); last[1]("open"); } },
        h(Text, { size: 12 }, "Open modal")),
      h(Text, { size: 12, color: "secondary", wrap: true, testID: "modal-body" }, "The close button, Escape or Done closes it."),
      h(Stack, { axis: "h", fillWidth: true },
        h(Spacer),
        h(Button, { style: "prominent", shortcut: "default", testID: "modal-done", onPress: function () { close("done"); } },
          h(Text, null, "Done")))),
    h(Modal, { isPresented: overrideOpen[0], width: 320, title: "Compact modal", icon: "macwindow", inset: 0, spacing: 4, testID: "modal-override", onDismiss: function () { overrideOpen[1](false); } },
      h(Button, { style: "bordered", testID: "modal-override-open", onPress: function () { overrideOpen[1](true); } },
        h(Text, { size: 12 }, "Open compact modal")),
      h(Text, { size: 12, testID: "modal-override-body" }, "Inset 0, spacing 4.")),
    h(Modal, {
      isPresented: requiredOpen[0], width: 320, title: "Required choice", icon: "macwindow", dismissible: false, testID: "modal-required",
      onDismiss: function () { last[1]("required dismiss"); }
    },
      h(Button, { style: "bordered", testID: "modal-required-open", onPress: function () { requiredOpen[1](true); last[1]("required open"); } },
        h(Text, { size: 12 }, "Open required modal")),
      h(Text, { size: 12, color: "secondary", wrap: true, testID: "modal-required-body" }, "No close button, and Escape does nothing: only Choose closes it."),
      h(Stack, { axis: "h", fillWidth: true },
        h(Spacer),
        h(Button, { style: "prominent", testID: "modal-required-choose", onPress: function () { requiredOpen[1](false); last[1]("required choose"); } },
          h(Text, null, "Choose")))),
    h(Text, { size: 11, color: "secondary", testID: "modal-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

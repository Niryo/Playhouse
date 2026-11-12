// Page: slides in from the trailing edge over all of its first child, which
// stays laid out as usual and sizes the atom, and shows the rest in a leading
// column on the window background while isPresented (the Scheduled Tasks page
// over the board). It is controlled: the owner closes it with its own
// control, here the page's Back button.
function Demo() {
  var open = React.useState(false);
  var last = React.useState("none");
  function close(how) { open[1](false); last[1](how); }
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Page, { isPresented: open[0], testID: "page-demo" },
      h(Stack, { axis: "v", spacing: 8, align: "leading", fill: "primary", fillOpacity: 0.04, cornerRadius: 8, width: 420, height: 220, paddingX: 16, paddingY: 16, group: true, testID: "page-base" },
        h(Text, { size: 13, weight: "semibold" }, "The view the page covers"),
        h(Button, { style: "bordered", testID: "page-open", onPress: function () { open[1](true); last[1]("open"); } },
          h(Text, { size: 12 }, "Open page"))),
      h(Stack, { axis: "h", spacing: 8, padding: 16 },
        h(Button, { style: "borderless", testID: "page-back", label: "Back", help: "Back", onPress: function () { close("back"); } },
          h(Icon, { name: "chevron.left", size: 13, weight: "semibold" })),
        h(Text, { size: 15, weight: "semibold", testID: "page-title" }, "Page content")),
      h(Divider),
      h(Text, { size: 11, color: "secondary", padding: 16 }, "Back closes it.")),
    h(Text, { size: 11, color: "secondary", testID: "page-last" }, "Last: ", last[0]));
}

Playhouse.render(h(Demo));

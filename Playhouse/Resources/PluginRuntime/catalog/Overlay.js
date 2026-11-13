// Overlay: its first child laid out as usual, the rest drawn over it at
// `align`, moved by offsetX and offsetY without changing its size.
function Demo() {
  var removed = React.useState(0);
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Text, { size: 11, color: "secondary" }, "align: \"topTrailing\", offsetX: 6, offsetY: -6"),
    h(Overlay, { align: "topTrailing", offsetX: 6, offsetY: -6, testID: "overlay-demo" },
      h(Panel, { fill: "primary", fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14, padding: 7, paddingX: 5.5, testID: "overlay-base" },
        h(Text, { size: 13, weight: "semibold" }, "A chip")),
      h(Button, { testID: "overlay-badge", label: "Remove", help: "Remove", onPress: function () { removed[1](removed[0] + 1); } },
        h(Panel, { fill: "panel", fillOpacity: 1, capsule: true, stroke: "primary", strokeOpacity: 0.16, width: 20, height: 20, padding: 0 },
          h(Icon, { name: "xmark", size: 9, weight: "bold", color: "secondary" })))),
    h(Text, { size: 11, color: "secondary", testID: "overlay-count" }, "Pressed the badge ", String(removed[0]), " times"));
}

Playhouse.render(h(Demo));

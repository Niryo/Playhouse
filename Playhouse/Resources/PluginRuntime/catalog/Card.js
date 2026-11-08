// Card: the task item's surface. Clicking it calls onPress; right-click shows `menu` and calls onMenu
// with the item's id; `meter` (0...1) fills the leading edge.
function Demo() {
  var pressed = React.useState(0);
  var menu = React.useState("none");
  return h(Stack, { axis: "v", spacing: 10, align: "leading", width: 280 },
    h(Card, {
      testID: "card-demo", label: "Demo card", hint: "Press the card", fillWidth: true, padding: 14,
      meter: 0.6, meterLabel: "CPU 60%", meterTestID: "card-meter",
      menu: [
        { id: "rename", title: "Rename…", icon: "pencil" },
        { id: "delete", title: "Delete", icon: "trash", destructive: true }
      ],
      onPress: function () { pressed[1](pressed[0] + 1); },
      onMenu: menu[1]
    },
      h(Stack, { axis: "v", spacing: 6, align: "leading", passThrough: true },
        h(Text, { size: 13, weight: "semibold", color: "text" }, "Click or right-click me"),
        h(Text, { size: 10, color: "secondary" }, "Content with passThrough lets clicks reach the card."))),
    h(Text, { size: 11, color: "secondary", testID: "card-pressed" }, "Pressed ", String(pressed[0]), " times"),
    h(Text, { size: 11, color: "secondary", testID: "card-menu" }, "Menu: ", menu[0]));
}

Playhouse.render(h(Demo));

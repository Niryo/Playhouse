// Toggle: a switch. It is controlled: `isOn` is what it shows, and a click
// calls onToggle, whose owner flips the state it holds.
function Demo() {
  var on = React.useState(true);
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Stack, { axis: "h", spacing: 12 },
      h(Toggle, { isOn: on[0], size: "mini", testID: "toggle-demo", label: "Demo enabled", help: "Turn the demo on or off", onToggle: function () { on[1](!on[0]); } }),
      h(Toggle, { isOn: true, size: "small", testID: "toggle-small", label: "Small switch" }),
      h(Toggle, { isOn: false, disabled: true, testID: "toggle-disabled", label: "Disabled switch" })),
    h(Text, { size: 11, color: "secondary", testID: "toggle-state" }, on[0] ? "On" : "Off"));
}

Playhouse.render(h(Demo));

// Button: its children are the label; onPress runs in JavaScript.
function Demo() {
  var count = React.useState(0);
  var press = function () { count[1](count[0] + 1); };
  return h(Stack, { axis: "v", spacing: 12, align: "leading" },
    h(Stack, { axis: "h", spacing: 12 },
      h(Button, { testID: "button-plain", onPress: press }, h(Text, { size: 11, weight: "medium" }, "Plain")),
      h(Button, { style: "borderless", testID: "button-borderless", onPress: press }, h(Text, { size: 11, weight: "medium", color: "accent" }, "Borderless")),
      h(Button, { style: "borderless", emphasis: 10, width: 30, height: 30, help: "Hover for the capsule", testID: "button-emphasis", onPress: press },
        h(Text, { size: 10, weight: "semibold" }, "PR")),
      h(Button, { style: "borderless", emphasis: 10, width: 30, height: 30, testID: "button-icon", label: "Check", onPress: press },
        h(Icon, { name: "checkmark", size: 11, weight: "bold", color: "green" })),
      h(Button, { disabled: true, testID: "button-disabled", onPress: press }, h(Text, { size: 11, color: "tertiary" }, "Disabled")),
      h(Button, { style: "borderless", emphasis: 10, width: 30, height: 30, disabled: true }, h(Spinner, { size: "mini" }))),
    h(Text, { size: 11, color: "secondary", testID: "button-press-count" }, "Pressed ", String(count[0]), " times"));
}

Playhouse.render(h(Demo));

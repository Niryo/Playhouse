// Meter: a horizontal usage bar filled to `fraction` (0...1).
function Demo() {
  var value = React.useState(0.25);
  return h(Stack, { axis: "v", spacing: 10, align: "leading", width: 220 },
    h(Meter, { fraction: value[0], testID: "meter-demo", label: "Usage", value: Math.round(value[0] * 100) + "%" }),
    h(Meter, { fraction: 0.86, color: "orange" }),
    h(Meter, { fraction: 1, color: "red", thickness: 6 }),
    h(Button, { style: "borderless", testID: "meter-add", onPress: function () { value[1](Math.min(1, value[0] + 0.25)); } },
      h(Text, { size: 11, weight: "medium", color: "accent" }, "Add 25%")),
    h(Text, { size: 11, color: "secondary", testID: "meter-value" }, String(Math.round(value[0] * 100)), "%"));
}

Playhouse.render(h(Demo));

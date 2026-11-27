// Segmented: a segmented control. It is controlled: `selected` is what it
// shows, and choosing a segment calls onChange with its value. `style: "menu"`
// shows the same choice as a pop-up button and `style: "radio"` as radio
// buttons.
function Demo() {
  var selected = React.useState("repo");
  var options = [
    { value: "repo", label: "Repo" },
    { value: "global", label: "Global" },
    { value: "builtin", label: "Built-in" }
  ];
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Segmented, { options: options, selected: selected[0], testID: "segmented-demo", label: "Source", onChange: selected[1] }),
    h(Segmented, { options: options, selected: "global", width: 260, disabled: true, testID: "segmented-disabled", label: "Disabled source" }),
    h(Text, { size: 11, color: "secondary", testID: "segmented-selected" }, "Selected: ", selected[0]),
    h(Segmented, { options: options, selected: selected[0], style: "menu", testID: "segmented-menu", label: "Source menu", onChange: selected[1] }),
    h(Segmented, { options: options, selected: selected[0], style: "radio", testID: "segmented-radio", label: "Source radio", onChange: selected[1] }));
}

Playhouse.render(h(Demo));

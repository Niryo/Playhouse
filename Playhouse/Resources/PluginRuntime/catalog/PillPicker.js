// PillPicker: shows the selected option; clicked, it opens into every option. onChange gets the value.
function Demo() {
  var selected = React.useState("autopilot");
  var options = [
    { value: "manual", label: "Manual", help: "You open the pull request yourself", testID: "pill-option-manual" },
    { value: "pr", label: "PR", help: "Open the pull request at Review", testID: "pill-option-pr" },
    { value: "autopilot", label: "Green", help: "Keep the PR green", testID: "pill-option-autopilot" },
    { value: "merge", label: "Merge", help: "Merge once green", testID: "pill-option-merge" }
  ];
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(PillPicker, { options: options, selected: selected[0], testID: "pill-picker", label: "Mode", help: "{help}. Click to choose another mode.", onChange: selected[1] }),
    h(Text, { size: 11, color: "secondary", testID: "pill-selected" }, "Selected: ", selected[0]));
}

Playhouse.render(h(Demo));

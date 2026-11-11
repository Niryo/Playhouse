// ChoiceBar: a row of mutually exclusive choices, each its own button. It is
// controlled: `selected` is what it shows, and onChange gets the chosen value.
// A composite: every capability it has is reachable through a decorated row
// Stack of Buttons marked `selected`, each label a decorated Stack around a
// Text, as ComposedDemo below builds it.
function Demo() {
  var selected = React.useState("overview");
  var options = [
    { value: "overview", label: "Overview", testID: "choice-overview" },
    { value: "wasters", label: "Wasters", testID: "choice-wasters" },
    { value: "tools", label: "Tools & MCP", testID: "choice-tools" }
  ];
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(ChoiceBar, { options: options, selected: selected[0], testID: "choice-bar", onChange: selected[1] }),
    h(Text, { size: 11, color: "secondary", testID: "choice-selected" }, "Selected: ", selected[0]));
}

// The same bar composed from atoms: a decorated row Stack of Buttons, each
// marked `selected` and drawn on a decorated Stack. It keeps its own choice.
function ComposedDemo() {
  var selected = React.useState("overview");
  var options = [
    { value: "overview", label: "Overview" },
    { value: "wasters", label: "Wasters" },
    { value: "tools", label: "Tools & MCP" }
  ];
  return h(Stack, { axis: "v", spacing: 10, align: "leading" },
    h(Stack, { axis: "h", spacing: 2, fill: "primary", fillOpacity: 0.06, cornerRadius: 7, padding: 2, group: true, testID: "choice-bar-composed" },
      options.map(function (option) {
        var isSelected = option.value === selected[0];
        return h(Button, { key: option.value, selected: isSelected, help: option.label, testID: "choice-composed-" + option.value,
          onPress: function () { if (!isSelected) selected[1](option.value); } },
          h(Stack, { fill: "accent", fillOpacity: isSelected ? 0.2 : 0, cornerRadius: 5, paddingX: 10, paddingY: 4 },
            h(Text, { size: 11, weight: isSelected ? "semibold" : "regular" }, option.label)));
      })),
    h(Text, { size: 11, color: "secondary", testID: "choice-composed-selected" }, "Composed: ", selected[0]));
}

Playhouse.render(h(Stack, { axis: "v", spacing: 20, align: "leading" }, h(Demo), h(ComposedDemo)));

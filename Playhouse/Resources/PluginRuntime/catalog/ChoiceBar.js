// ChoiceBar: a row of mutually exclusive choices, each its own button. It is
// controlled: `selected` is what it shows, and onChange gets the chosen value.
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

Playhouse.render(h(Demo));

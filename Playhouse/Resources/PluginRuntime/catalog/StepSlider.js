// StepSlider: a discrete slider over options, controlled by selected. A click,
// a drag or the arrow keys call onChange with the option's value.
function Demo() {
  var selected = React.useState("medium");
  var options = [
    { value: "low", label: "Low" }, { value: "medium", label: "Medium" },
    { value: "high", label: "High" }, { value: "xhigh", label: "Extra High" }
  ];
  var label = options.filter(function (option) { return option.value === selected[0]; })[0].label;
  return h(Stack, { axis: "v", spacing: 8, align: "leading", width: 260 },
    h(Text, { size: 14, weight: "medium", color: "accent", testID: "step-slider-label" }, label),
    h(StepSlider, { options: options, selected: selected[0], testID: "step-slider-demo", label: "Effort", onChange: selected[1] }));
}

Playhouse.render(h(Demo));

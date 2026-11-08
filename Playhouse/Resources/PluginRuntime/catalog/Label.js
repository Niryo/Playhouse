// Label: an SF Symbol beside a string.
Playhouse.render(h(Stack, { axis: "v", spacing: 10, align: "leading" },
  h(Label, { text: "in 2 hours", icon: "clock", size: 10, weight: "medium", color: "accent", testID: "label-schedule" }),
  h(Label, { text: "Waiting on review", icon: "eye", size: 11, color: "secondary" }),
  h(Label, { text: "Merged", icon: "checkmark.circle", size: 12, weight: "semibold", color: "purple" })
));

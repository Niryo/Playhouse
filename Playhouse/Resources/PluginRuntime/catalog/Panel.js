// Panel: a rounded, filled background behind a leading column of its children.
Playhouse.render(h(Stack, { axis: "v", spacing: 12, align: "leading", width: 220 },
  h(Text, { size: 11, color: "secondary" }, "Default fill (primary at 0.05), spacing: 4, padding: 8"),
  h(Panel, { spacing: 4, fillWidth: true, padding: 8, testID: "panel-default" },
    h(Text, { size: 11, weight: "semibold" }, "Claude"),
    h(Text, { size: 9, color: "secondary" }, "One block of the Agents info section")),
  h(Text, { size: 11, color: "secondary" }, "fill: \"accent\", fillOpacity: 0.18, cornerRadius: 5"),
  h(Panel, { fill: "accent", fillOpacity: 0.18, cornerRadius: 5, fillWidth: true, padding: 3, testID: "panel-accent" },
    h(Stack, { axis: "h" },
      h(Spacer, { minLength: 0 }),
      h(Text, { size: 10, weight: "medium" }, "Log in"),
      h(Spacer, { minLength: 0 })))
));

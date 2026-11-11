// Panel: a composite atom, shorthand for a column Stack with a surface and
// group: true. Its only difference from that Stack is its defaults: fill
// "primary" at fillOpacity 0.05, cornerRadius 8 and align "leading". Each
// Panel below sits beside the Stack it stands for.
Playhouse.render(h(Stack, { axis: "v", spacing: 12, align: "leading", width: 460 },
  h(Text, { size: 11, color: "secondary" }, "Default fill (primary at 0.05), spacing: 4, padding: 8"),
  h(Stack, { axis: "h", spacing: 12, align: "top" },
    h(Panel, { spacing: 4, width: 220, padding: 8, testID: "panel-default" },
      h(Text, { size: 11, weight: "semibold" }, "Claude"),
      h(Text, { size: 9, color: "secondary" }, "One block of the Agents info section")),
    h(Stack, { axis: "v", spacing: 4, align: "leading", group: true, fill: "primary", fillOpacity: 0.05, cornerRadius: 8,
      width: 220, padding: 8, testID: "panel-default-stack" },
      h(Text, { size: 11, weight: "semibold" }, "Claude"),
      h(Text, { size: 9, color: "secondary" }, "One block of the Agents info section"))),
  h(Text, { size: 11, color: "secondary" }, "fill: \"accent\", fillOpacity: 0.18, cornerRadius: 5"),
  h(Panel, { fill: "accent", fillOpacity: 0.18, cornerRadius: 5, width: 220, padding: 3, testID: "panel-accent" },
    h(Stack, { axis: "h" },
      h(Spacer, { minLength: 0 }),
      h(Text, { size: 10, weight: "medium" }, "Log in"),
      h(Spacer, { minLength: 0 }))),
  h(Text, { size: 11, color: "secondary" }, "The same as a decorated row, with no nested Stack"),
  h(Stack, { axis: "h", group: true, fill: "accent", fillOpacity: 0.18, cornerRadius: 5, width: 220, padding: 3, testID: "panel-accent-stack" },
    h(Spacer, { minLength: 0 }),
    h(Text, { size: 10, weight: "medium" }, "Log in"),
    h(Spacer, { minLength: 0 })),
  h(Text, { size: 11, color: "secondary" }, "capsule: true, stroke: \"primary\", strokeOpacity: 0.14"),
  h(Stack, { axis: "h", spacing: 12 },
    h(Panel, { fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14, padding: 7, paddingX: 5.5, testID: "panel-capsule" },
      h(Text, { size: 13, weight: "semibold" }, "Capsule")),
    h(Stack, { axis: "v", align: "leading", group: true, fill: "primary", fillOpacity: 0.08, capsule: true, stroke: "primary", strokeOpacity: 0.14,
      padding: 7, paddingX: 5.5, testID: "panel-capsule-stack" },
      h(Text, { size: 13, weight: "semibold" }, "Capsule")))
));
